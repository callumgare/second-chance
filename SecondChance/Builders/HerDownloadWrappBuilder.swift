//
//  HerDownloadWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from a game bought from
//  Her Interactive's store: a Windows installer (.exe) or a Mac download
//  (.dmg).
//
//  A Windows installer is unpacked into the layout a disc has and installed
//  as one is; a Mac download is a Cider (Wine) app with the installed
//  Windows game inside, which is lifted straight out. Both then go through
//  the same shared tail as the other sources, so they sign and publish the
//  same events. docs/her-download.md has the details of both formats.
//

import Foundation
import Logging
import SecondChanceKit
import GameCatalog
import WrappBuilder

/// Builds a wrapp from a Her Interactive download.
final class HerDownloadWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameDetector: GameDetector
    private let gameInfoProvider: GameInfoProvider
    private let isoMounter: ISOMounter
    private let wineManager: WineManager
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.HerDownloadWrappBuilder")
    private let fileManager = FileManager.default

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameDetector: GameDetector = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        isoMounter: ISOMounter = ISOMounter(),
        wineManager: WineManager = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameDetector = gameDetector
        self.gameInfoProvider = gameInfoProvider
        self.isoMounter = isoMounter
        self.wineManager = wineManager
        self.bus = bus
    }

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .herDownload))

        var download = try await input.getHerInstallerPath()
        while true {
            do {
                return try await build(fromDownload: download, input: input)
            } catch is ChooseAnotherDownload {
                // Its game wasn't recognised, and the person chose another.
                download = try await input.getHerInstallerPath()
            }
        }
    }

    /// Thrown once a download's game wasn't recognised and the person chose
    /// another download, after cleaning up after this one.
    private struct ChooseAnotherDownload: Error {}

    private func build(fromDownload download: URL, input: WrappBuildInput) async throws -> URL {
        logger.notice("Her Interactive download: \(download.path)")
        switch download.pathExtension.lowercased() {
        case "dmg":
            return try await build(fromMacDownload: download, input: input)
        case "app":
            // The installer app inside an opened Mac download: its volume is
            // the download, mounted already.
            return try await build(fromMacDownload: download.deletingLastPathComponent(), input: input)
        default:
            break
        }
        return try await build(fromWindowsInstaller: download, input: input)
    }

    /// Throws `ChooseAnotherDownload` when the game isn't one Second Chance
    /// recognises and the person would rather choose another download.
    private func checkRecognised(_ gameInfo: GameInfo, input: WrappBuildInput) async throws {
        guard gameInfo.id == GameInfo.unknownGame.id else { return }
        if try await input.askAboutUnrecognisedGame(.herDownload) == .chooseAnother {
            throw ChooseAnotherDownload()
        }
    }

    // MARK: - Windows installer

    private func build(fromWindowsInstaller installer: URL, input: WrappBuildInput) async throws -> URL {
        // ── Detect ONCE ────────────────────────────────────────────────
        let gameInfo: GameInfo
        do {
            await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
            let gameSlug = try await gameDetector.detectGame(fromHerInstaller: installer)
            gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
            logger.notice("Detected game: \(gameInfo.title)")
            try await checkRecognised(gameInfo, input: input)
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
        } catch {
            await publishFailure(error)
            throw error
        }

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            // Unpacked, then installed: the installer's own size each time,
            // and as much again for what it was compressed from.
            try await helper.ensureRoomToBuild(from: installer, copies: 3)
            try await helper.createBaseWrapp(at: wrappPath, composition: gameInfo.composition)
            // The game's bundle says what building Her's Windows download
            // runs (its Wrappfile's her-download stage).
            guard let plan = try await Blocking.run({ try ShippedBundles.plan(forGame: gameInfo.id, edition: "her-windows") }) else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s her-windows edition names no stage")
            }
            // The same download, plan and modules install the same game: a
            // build after the first clones its install (docs/wrapp-build.md#the-layer-cache).
            let key: LayerKey? = DebugSettings.shared.skipInstaller ? nil : try await Blocking.run {
                try InstallLayer.key(slot: "\(gameInfo.id) \(plan.edition): install", plan: plan, wrappPath: wrappPath, inputs: [
                    .init("download", try LayerKey.hash(file: installer)),
                ])
            }
            let installed = try await InstallLayer(store: wineManager.layers, bus: bus).run(
                key: key, wrappPath: wrappPath, gameInfo: gameInfo, disk1: nil
            ) { () async throws -> InstallLayer.Installed in
                var gameExePath: String?
                var configuredINI = false
                for step in plan.bundleSteps where !WrappBuildHelper.isAppStep(step) {
                    logger.debug("Plan step: \(step) (\(step.origin))")
                    switch (step.module, step.instruction) {
                    case _ where WineSteps.handles(step):
                        try await WineSteps(bus: bus).run(step, wrappPath: wrappPath)
                    case ("her-download", "INSTALL"):
                        gameExePath = try await installWindowsDownload(installer, wrappPath: wrappPath, gameInfo: gameInfo,
                                                                       answerFile: step.option("answer-file").flatMap(plan.file),
                                                                       automation: step.option("automation").flatMap(plan.file),
                                                                       creates: try GameInstallerRunner.expectedProgram(of: step),
                                                                       input: input)
                    case _ where GameInstallerRunner.isPatchStep(step):
                        try await installerRunner.runPatchStep(step, plan: plan, wrappPath: wrappPath, gameInfo: gameInfo,
                                                               source: .herDownload, confirmFailure: input.confirmPatchFailure)
                    case (nil, "EDIT") where step.option("from-data") == "ini":
                        if let gameExePath {
                            try helper.configureGameINI(in: WrappLayout(app: wrappPath).onDriveC(gameExePath).deletingLastPathComponent())
                        }
                        configuredINI = true
                    default:
                        throw WrappBuildError.buildRecipeProblem("\(step.origin): the Her download flow can't run \(step)")
                    }
                }
                guard let gameExePath else {
                    throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s her-windows plan installs nothing")
                }
                return InstallLayer.Installed(gameExePath: gameExePath, installerDir: "", configuredINI: configuredINI)
            }
            let gameExePath = installed.gameExePath
            try await helper.runAppSteps(plan, wrappPath: wrappPath, gameInfo: gameInfo) { _ in nil }

            if !DebugSettings.shared.skipInstaller {
                try await helper.cleanupUnusedEngine(at: wrappPath, composition: gameInfo.composition)
            }

            return try await finish(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                configureINI: false,
                edition: "her-windows",
                plan: plan,
                input: input
            )
        } catch {
            await helper.removeTempWrapp(wrappPath)
            await publishFailure(error)
            throw error
        }
    }

    /// `her-download.INSTALL` for a Windows download: an InstallShield
    /// launcher is unpacked into the layout a disc has and installed
    /// silently with the answer file, as a disc is; anything else runs as it
    /// is and asks its questions itself. Patches are steps of their own.
    /// The game's program, from the root of drive C.
    private func installWindowsDownload(
        _ installer: URL, wrappPath: URL, gameInfo: GameInfo, answerFile: URL?, automation: URL?, creates: String?,
        input: WrappBuildInput
    ) async throws -> String {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let installerBaseDir = driveCPath.appendingPathComponent(WrappLayout.installersFolder)
        await bus.publishWrappBuild(.progress(.copyingInstaller(substep: String(localized: "Unpacking the installer"))))
        let unpacked = try await installerRunner.unpackInstallShieldLauncher(installer, at: wrappPath)
        if unpacked, let source = answerFile {
            let destination = installerBaseDir.appendingPathComponent("setup.iss")
            try FileManager.default.createDirectory(at: installerBaseDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            logger.notice("✅ Copied \(gameInfo.id)'s \(source.lastPathComponent) to setup.iss")
        }

        // Both engines install under Wine: a ScummVM game's data is in the
        // installer's cabinets too, and ScummVM plays it from where the
        // installer put it. Wine is stripped from a ScummVM wrapp only once
        // the installer and the patches have run.
        await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
        try await publishEngineRoute(for: gameInfo)
        let (gameExePath, _) = try await installerRunner.installGameWithWine(
            wrappPath: wrappPath,
            gameInfo: gameInfo,
            source: .herDownload,
            installerPath: unpacked ? nil : installer,
            unattended: input.isUnattended,
            chooseGameProgram: input.chooseGameProgram(among:),
            automation: automation,
            creates: creates
        )

        // Unlike a disc, nothing reads the installer once the game is in.
        if unpacked && !DebugSettings.shared.skipInstaller {
            await removeQuietly(installerBaseDir, what: "the unpacked installer")
        }
        return gameExePath
    }

    // MARK: - Mac download

    /// `image` is the download's `.dmg`, or the volume it's already mounted
    /// at.
    private func build(fromMacDownload image: URL, input: WrappBuildInput) async throws -> URL {
        // ── Mount, recognise and detect ONCE ───────────────────────────
        let package: CiderPackage
        let gameInfo: GameInfo
        do {
            let volume: URL
            if image.pathExtension.lowercased() == "dmg" {
                // Second Chance isn't sandboxed, so the volume needs no grant.
                volume = try await isoMounter.mount(image)
                await bus.publishWrappBuild(.isoMounted(volume))
            } else {
                volume = image
            }

            await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
            do {
                package = try CiderPackage(volume: volume)
            } catch let notCider as CiderPackage.NotCider {
                logger.critical("\(image.lastPathComponent) isn't a Cider installer: \(notCider)")
                throw WrappBuildError.unsupportedMacDownload(
                    reason: "it isn't one of the Mac downloads made with Cider (\(notCider))")
            }
            let gameSlug = gameDetector.detectGame(fromCiderPackage: package)
            gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
            logger.notice("Detected game: \(gameInfo.title)")
            try await checkRecognised(gameInfo, input: input)
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
        } catch {
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            try await helper.ensureRoomToBuild(from: image, copies: 3)
            try await helper.createBaseWrapp(at: wrappPath, composition: gameInfo.composition)
            let driveCPath = WrappLayout(app: wrappPath).driveC
            // The game's bundle says what building Her's Mac download runs
            // (its Wrappfile's her-mac stage): taking the game out of the
            // Cider app, and the games' .ini settings.
            guard let plan = try await Blocking.run({ try ShippedBundles.plan(forGame: gameInfo.id, edition: "her-mac") }) else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s her-mac edition names no stage")
            }
            let steps = plan.bundleSteps
            for step in steps where !(step.module == "her-download" && step.instruction == "INSTALL")
                && !(step.module == nil && step.instruction == "EDIT" && step.option("from-data") == "ini")
                && !WrappBuildHelper.isAppStep(step) && !WineSteps.handles(step) {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): the Mac download flow can't run \(step)")
            }
            for step in steps where WineSteps.handles(step) {
                try await WineSteps(bus: bus).run(step, wrappPath: wrappPath)
            }
            let configuresINI = steps.contains { $0.instruction == "EDIT" }

            await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Unpacking the game"))))
            try await publishEngineRoute(for: gameInfo)

            // Staged inside the wrapp, so moving the game out of it into
            // drive_c is a rename rather than a copy.
            let staging = wrappPath.appendingPathComponent("Contents/SharedSupport/cider-staging")
            let bus = self.bus
            let wineDLLs = WrappLayout(app: wrappPath).wine.appendingPathComponent("lib/wine/i386-windows")
            let gameExe = try await package.extractGame(into: driveCPath, staging: staging, wineDLLs: wineDLLs) { percent in
                // On the progress bar: a substep changing every percent
                // would start the step's clock again each time.
                await bus.publishWrappBuild(.stepProgress(StepProgress(fraction: Double(percent) / 100, text: "\(percent)% unpacked")))
            }
            await removeQuietly(staging, what: "the rest of the Cider app")
            await isoMounter.unmountAll()

            // The game goes where the step's --into says, which the Cider app
            // may have put it elsewhere than.
            let into = steps.first { $0.module == "her-download" && $0.instruction == "INSTALL" }?.option("into")
            let movedExe = try moveExtractedGame(gameExe, to: into, driveC: driveCPath)
            let gameExePath = "/" + movedExe.path(relativeTo: driveCPath)
            await bus.publishWrappBuild(.gameExeDetected(path: gameExePath, gameInfo: gameInfo))
            try await helper.runAppSteps(plan, wrappPath: wrappPath, gameInfo: gameInfo) { _ in nil }

            // Her Interactive's patches are Windows updaters that look for
            // the game their own installer registered; a Cider build never
            // ran one, and it is a later build than they patch anyway, so the
            // her-mac stage has none.
            logger.notice("Not applying game patches: a Mac download is a later build than Her Interactive's patches update")

            try await helper.cleanupUnusedEngine(at: wrappPath, composition: gameInfo.composition)

            return try await finish(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                configureINI: configuresINI,
                edition: "her-mac",
                plan: plan,
                input: input
            )
        } catch {
            await helper.removeTempWrapp(wrappPath)
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }
    }

    // MARK: - Shared steps

    /// Publish which engine the game runs under; a Her download is only ever
    /// a Wine or a ScummVM game.
    private func publishEngineRoute(for gameInfo: GameInfo) async throws {
        switch gameInfo.composition.launcher {
        case .wine, .scummvm:
            await bus.publishWrappBuild(.engineRouted(composition: gameInfo.composition, gameInfo: gameInfo))
        default:
            throw WrappBuildError.unsupportedEngine
        }
    }

    /// Configure → sign → save → launch. ScummVM plays the game from its
    /// installed folder, which is the folder the exe is in for both formats.
    private func finish(
        wrappPath: URL,
        gameInfo: GameInfo,
        gameExePath: String,
        configureINI: Bool,
        edition: String,
        plan: BuildPlan,
        input: WrappBuildInput
    ) async throws -> URL {
        // A game whose data is copied into the app (ScummVM's) has no
        // program on C: for the settings' older keys to name.
        let inPrefix = plan.launch?.program.hasPrefix("wine:") ?? true
        let gameDir = (gameExePath as NSString).deletingLastPathComponent
        let finalPath = try await helper.completeBuild(
            wrapp: wrappPath, gameInfo: gameInfo, source: .herDownload,
            gameExePath: inPrefix ? gameExePath : "", installerDir: inPrefix ? gameDir : "", configureINI: configureINI,
            edition: edition, launch: plan.launch, icon: plan.icon, input: input
        )
        await helper.launchIfAsked(finalPath, input: input)
        return finalPath
    }

    private func publishFailure(_ error: Error) async {
        // Not a failure: the build carries on with another download.
        guard !(error is ChooseAnotherDownload) else { return }
        let buildError = WrappBuildError(error)
        await bus.publishWrappBuild(.failed(buildError))
    }

    /// The game a Cider app gave up, moved to the folder `into` names
    /// (`wine:C:/…`), the step's: the program's new place. The folder the
    /// app put it in must be there, or the move fails, naming it.
    private func moveExtractedGame(_ exe: URL, to into: String?, driveC: URL) throws -> URL {
        guard let into, into.hasPrefix("wine:C:/") else { return exe }
        let found = exe.deletingLastPathComponent()
        let target = WrappLayout.onDriveC(String(into.dropFirst("wine:C:".count)), in: driveC)
        guard found.standardizedFileURL != target.standardizedFileURL else { return exe }
        guard FileManager.default.fileExists(atPath: found.path) else {
            throw WrappBuildError.buildRecipeProblem("the Mac download's game isn't in \(found.path(relativeTo: driveC)), where its app says")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: found, to: target)
        logger.notice("Moved the game from \(found.path(relativeTo: driveC)) to \(into), as the Wrappfile says")
        return target.appendingPathComponent(exe.lastPathComponent)
    }

    /// Hundreds of MB, so off the main thread.
    private func removeQuietly(_ url: URL, what: String) async {
        do {
            try await Blocking.run { try FileManager.default.removeItem(at: url) }
        } catch {
            logger.warning("Couldn't remove \(what) at \(url.path): \(error)")
        }
    }
}
