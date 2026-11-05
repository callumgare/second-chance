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
import Synchronization
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
        do {
            // Unpacked, then installed: the installer's own size each time,
            // and as much again for what it was compressed from.
            try await helper.ensureRoomToBuild(from: installer, copies: 3)
        } catch {
            await publishFailure(error)
            throw error
        }
        return try await buildThroughRunner(gameInfo: gameInfo, edition: "her-windows", installer: installer, package: nil, input: input)
    }

    /// The edition's plan carried out by the runner, each stage in a tree of
    /// its own in a working folder this builder owns, the template laid in
    /// at the end; then configure, sign, save, launch. `installer` is the
    /// edition's input: the Windows installer, or the Mac download's volume.
    private func buildThroughRunner(gameInfo: GameInfo, edition: String, installer: URL, package: CiderPackage?,
                                    input: WrappBuildInput) async throws -> URL {
        let folder = helper.createBuildFolder()
        logger.notice("Working folder: \(folder.path)")
        await bus.publishWrappBuild(.wrappStarted(path: folder))
        do {
            guard let plan = try await Blocking.run({ try ShippedBundles.plan(forGame: gameInfo.id, edition: edition) }),
                  let launch = plan.launch else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s \(edition) edition names no stage")
            }
            let template = try await helper.template()
            await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))
            try await publishEngineRoute(for: gameInfo)
            let executor = HerDownloadExecutor(builder: self, gameInfo: gameInfo, package: package, input: input)
            let installers = InstallerExecutor(runner: installerRunner, gameInfo: gameInfo, source: .herDownload,
                                               installerName: nil, input: input)
            let (configuration, emitter) = AppRunner.configuration(
                bus: bus, input: input, game: gameInfo, inputs: GivenInputs(["installer": installer]),
                downloader: DownloadWrappBuilder.standardDownloader(), helper: helper,
                executors: ["her-download": executor, "installer": installers])
            let wrappPath: URL
            do {
                wrappPath = try await PlanRunner(plan: plan, configuration: configuration).build(in: folder)
            } catch let error as StepFailure {
                await emitter.finish()
                throw WrappBuildError.buildRecipeProblem(error.description)
            } catch {
                await emitter.finish()
                throw error
            }
            await emitter.finish()
            await isoMounter.unmountAll()
            try await Blocking.run { try WrappAssembler.layIn(template, into: wrappPath) }
            if launch.launcher() == .scummvm {
                await bus.publishWrappBuild(.gameExeDetected(path: "/SharedSupport/game", gameInfo: gameInfo))
            } else if !executor.installed && !installers.installed {
                // An install restored from a layer, which never said.
                await bus.publishWrappBuild(.gameExeDetected(path: String(launch.path.dropFirst(2)), gameInfo: gameInfo))
            }
            let finalPath = try await finish(wrappPath: wrappPath, gameInfo: gameInfo,
                                             gameExePath: launch.launcher() == .scummvm ? "" : String(launch.path.dropFirst(2)),
                                             edition: edition, plan: plan, input: input)
            await helper.removeTempWrapp(folder)
            return finalPath
        } catch {
            await helper.removeFailedBuild(folder)
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }
    }

    /// `her-download.INSTALL` for a Windows download: an InstallShield
    /// launcher is unpacked into the layout a disc has and installed
    /// silently with the answer file, as a disc is; anything else runs as it
    /// is and asks its questions itself. Patches are steps of their own.
    /// The game's program, from the root of drive C.
    func installWindowsDownload(
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
        do {
            try await helper.ensureRoomToBuild(from: image, copies: 3)
        } catch {
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }
        // Her Interactive's patches are Windows updaters that look for the
        // game their own installer registered; a Cider build never ran one,
        // and it is a later build than they patch anyway, so the her-mac
        // stage has none.
        return try await buildThroughRunner(gameInfo: gameInfo, edition: "her-mac", installer: package.volume, package: package, input: input)
    }

    /// `HER-DOWNLOAD.INSTALL` for a Mac download: the Windows game taken out
    /// of the Cider app into drive C, moved where `--into` says. The game's
    /// program, from the root of drive C.
    func extractMacDownload(_ package: CiderPackage, wrappPath: URL, into: String?, gameInfo: GameInfo) async throws -> String {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        await bus.publishWrappBuild(.progress(.installingGame(substep: String(localized: "Unpacking the game"))))
        // Staged inside the tree, so moving the game out of it into drive_c
        // is a rename rather than a copy.
        let staging = wrappPath.appendingPathComponent("Contents/SharedSupport/cider-staging")
        let bus = self.bus
        let wineDLLs = WrappLayout(app: wrappPath).wine.appendingPathComponent("lib/wine/i386-windows")
        let gameExe = try await package.extractGame(into: driveCPath, staging: staging, wineDLLs: wineDLLs) { percent in
            // On the progress bar: a substep changing every percent would
            // start the step's clock again each time.
            await bus.publishWrappBuild(.stepProgress(StepProgress(fraction: Double(percent) / 100, text: "\(percent)% unpacked")))
        }
        await removeQuietly(staging, what: "the rest of the Cider app")
        // The game goes where the step's --into says, which the Cider app
        // may have put it elsewhere than.
        let movedExe = try moveExtractedGame(gameExe, to: into, driveC: driveCPath)
        let gameExePath = "/" + movedExe.path(relativeTo: driveCPath)
        await bus.publishWrappBuild(.gameExeDetected(path: gameExePath, gameInfo: gameInfo))
        return gameExePath
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
            gameExePath: inPrefix ? gameExePath : "", installerDir: inPrefix ? gameDir : "",
            edition: edition, launch: plan.launch, app: plan.app, input: input
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

/// The her-download module's executor, until its kit moves into its
/// package: `HER-DOWNLOAD.INSTALL`, a Windows download installed as a disc
/// is, or a Mac download's Windows game taken out of its Cider app.
nonisolated final class HerDownloadExecutor: ModuleExecutor, @unchecked Sendable {
    static let handles = ["INSTALL"]

    let builder: HerDownloadWrappBuilder
    let gameInfo: GameInfo
    /// The Mac download being built from; nil for a Windows one.
    let package: CiderPackage?
    let input: WrappBuildInput
    /// Whether the install ran, rather than being restored from a layer.
    var installed: Bool { ran.withLock { $0 } }
    private let ran = Mutex(false)

    init(builder: HerDownloadWrappBuilder, gameInfo: GameInfo, package: CiderPackage?, input: WrappBuildInput) {
        self.builder = builder
        self.gameInfo = gameInfo
        self.package = package
        self.input = input
    }

    func run(_ step: PlannedStep, in context: any StepContext) async throws {
        defer { ran.withLock { $0 = true } }
        if let package {
            _ = try await builder.extractMacDownload(package, wrappPath: context.tree, into: step.option("into"), gameInfo: gameInfo)
            return
        }
        guard let name = step.arguments.first.flatMap(PlannedStep.input(in:)) else {
            throw StepFailure.recipe("\(step.origin): HER-DOWNLOAD.INSTALL installs an input")
        }
        let installer = try await context.input(name)
        _ = try await builder.installWindowsDownload(
            installer, wrappPath: context.tree, gameInfo: gameInfo,
            answerFile: step.option("answer-file").flatMap(context.file),
            automation: step.option("automation").flatMap(context.file),
            creates: try GameInstallerRunner.expectedProgram(of: step), input: input)
    }
}
