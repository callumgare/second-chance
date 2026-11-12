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
//  Windows game inside, which is lifted straight out, unless the download is
//  the game's Windows and Mac disc, which builds as its disc does. All then go through
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
        case "dmg", "sparsebundle":
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
        return try await buildThroughRunner(gameInfo: gameInfo, edition: "her-windows", inputs: GivenInputs(["installer": installer]),
                                            package: nil, input: input)
    }

    /// The edition's plan carried out by the runner, each stage in a tree of
    /// its own in a working folder this builder owns, the template laid in
    /// at the end; then configure, sign, save, launch. `inputs` are the
    /// edition's: the Windows installer or the Mac download's volume as
    /// `installer`, or for a download that is a disc, its discs.
    /// `installerName` is the program to install a disc with when it has
    /// no installer by name.
    private func buildThroughRunner(gameInfo: GameInfo, edition: String, inputs: any InputProvider, package: CiderPackage?,
                                    installerName: String? = nil, everyDiscOnOne: Bool = false, input: WrappBuildInput) async throws -> URL {
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
                                               installerName: installerName, input: input, everyDiscOnOne: everyDiscOnOne)
            let (configuration, emitter) = AppRunner.configuration(
                bus: bus, input: input, game: gameInfo, inputs: inputs,
                downloader: DownloadWrappBuilder.standardDownloader(), helper: helper,
                executors: ["her-download": executor, "installer": installers])
            let wrappPath: URL
            do {
                wrappPath = try await PlanRunner(plan: plan, configuration: configuration).build(in: folder)
            } catch let error as StepFailure {
                await emitter.finish()
                throw WrappBuildError(stepFailure: error)
            } catch {
                await emitter.finish()
                throw error
            }
            await emitter.finish()
            await isoMounter.unmountAll()
            try await Blocking.run { try WrappAssembler.layIn(template, into: wrappPath) }
            // A program on a drive was announced by its install, unless that
            // was restored from a layer, which never said; any other (a
            // ScummVM game's folder) is announced now.
            let onDrive = launch.legacyProgramPath(places: helper.places)
            if onDrive == nil || (!executor.installed && !installers.installed) {
                await bus.publishWrappBuild(.gameExeDetected(path: launch.shownPath(places: helper.places), gameInfo: gameInfo))
            }
            let finalPath = try await finish(wrappPath: wrappPath, gameInfo: gameInfo,
                                             gameExePath: onDrive ?? "",
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

    /// `image` is the download's `.dmg` (or a sparse bundle of one), or the
    /// volume it's already mounted at. Its game is in the Cider app it
    /// installs, or beside its installer when the image is the game's disc
    /// (`CiderPackage.GameSource`).
    private func build(fromMacDownload image: URL, input: WrappBuildInput) async throws -> URL {
        // ── Mount, recognise and detect ONCE ───────────────────────────
        // The Cider installer, unless the image is only a Windows disc.
        let package: CiderPackage?
        let source: CiderPackage.GameSource
        let volume: URL
        let gameInfo: GameInfo
        // For an image that is the game's disc, the program to install it
        // with when it has no installer by name.
        var installerName: String?
        do {
            if ISOMounter.isMacDiskImage(image) {
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
                // A hybrid disc's image whose Mac side macOS can't mount
                // shows only its Windows side: still the game's disc.
                let lookup = (try? GameDetector.installerLookup(in: volume)) ?? GameDetector.InstallerLookup.none
                guard case .recognised = lookup else {
                    logger.critical("\(image.lastPathComponent) isn't a Cider installer: \(notCider)")
                    throw WrappBuildError.unsupportedMacDownload(
                        reason: "it isn't one of the Mac downloads made with Cider (\(notCider))")
                }
                logger.notice("\(image.lastPathComponent) isn't a Cider installer (\(notCider)), but has a Windows installer: it's the game's disc")
                package = nil
            }
            source = package?.game ?? .disc(missingDiscs: [])
            var gameSlug = package.map(gameDetector.detectGame(fromCiderPackage:)) ?? GameInfo.unknownGame.id
            if case .disc = source, gameSlug == GameInfo.unknownGame.id {
                // A disc says more of itself than its Mac installer does.
                gameSlug = try await gameDetector.detectGame(fromDisk: volume)
            }
            gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
            logger.notice("Detected game: \(gameInfo.title)")
            try await checkRecognised(gameInfo, input: input)
            if case .disc = source {
                installerName = try await discInstaller(on: volume, gameInfo: gameInfo, input: input)
            }
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
        } catch {
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }

        switch source {
        case .payload:
            guard let package else { throw WrappBuildError.internalError("A Mac download's game is in a Cider app it hasn't") }
            // ── Build ──────────────────────────────────────────────────
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
            return try await buildThroughRunner(gameInfo: gameInfo, edition: "her-mac", inputs: GivenInputs(["installer": package.volume]),
                                                package: package, input: input)
        case .disc(let missingDiscs):
            return try await build(fromDisc: volume, missingDiscs: missingDiscs, discCount: package?.discCount ?? 1, gameInfo: gameInfo,
                                   installerName: installerName, input: input)
        }
    }

    // MARK: - Mac download that is a disc

    /// The program on a disc's image to install the game with: nil when it
    /// has an installer by name, or the one the person chose when it
    /// hasn't. Refuses an image with no Windows installer at all, and a
    /// game that isn't installed under Wine.
    private func discInstaller(on volume: URL, gameInfo: GameInfo, input: WrappBuildInput) async throws -> String? {
        guard gameInfo.composition.launcher == .wine else {
            logger.critical("\(gameInfo.id) is on its Mac download's disc, and doesn't run under Wine")
            throw WrappBuildError.unsupportedMacDownload(reason: "its game is on the disc beside the installer, and isn't one Wine installs")
        }
        switch try GameDetector.installerLookup(in: volume) {
        case .recognised(let name):
            logger.notice("The Mac download is the game's disc; installing it with its Windows installer, \(name)")
            return nil
        case .none:
            logger.critical("The Mac download's game isn't in its Cider app, and there's no Windows installer beside it")
            throw WrappBuildError.unsupportedMacDownload(reason: "its game isn't in its Cider app, and it has no Windows installer")
        case .unrecognised(let programs):
            switch try await input.askAboutUnidentifiedInstaller(programs: programs) {
            case .tryProgram(let program):
                return program
            case .chooseAnother:
                throw ChooseAnotherDownload()
            }
        }
    }

    /// A Mac download whose game is on the image beside the installer: the
    /// game's Windows and Mac disc, so it builds as the disc does, from the
    /// bundle's disc edition with the image as disc 1, installed with the
    /// Windows installer on it, Her's patches and all. An image holding
    /// every disc's files (`missingDiscs` empty) is the only disc; else the
    /// person is asked for disc 2 as for a disc build.
    private func build(fromDisc volume: URL, missingDiscs: [String], discCount: Int, gameInfo: GameInfo, installerName: String?,
                       input: WrappBuildInput) async throws -> URL {
        let edition: String
        do {
            let discs = missingDiscs.isEmpty ? 1 : max(gameInfo.diskCount, 2)
            // Each disc copied into the app, and the game installed from them.
            try await helper.ensureRoomToBuild(from: volume, copies: 2 * discs)
            edition = try await Blocking.run { try ShippedBundles.edition(ofGame: gameInfo.id, source: .disk) }
        } catch {
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }
        let without = missingDiscs.isEmpty ? "" : " (without \(missingDiscs.joined(separator: ", ")))"
        logger.notice("Building \(gameInfo.id)'s \(edition) edition from the Mac download, which is its disc\(without)")
        let inputs = DiscInputs(disc1: volume, diskCount: missingDiscs.isEmpty ? 1 : gameInfo.diskCount) { [self] in
            try await self.resolveDisc2(of: gameInfo, disc1: volume, asked: !missingDiscs.isEmpty, input: input)
        }
        return try await buildThroughRunner(gameInfo: gameInfo, edition: edition, inputs: inputs, package: nil,
                                            installerName: installerName, everyDiscOnOne: missingDiscs.isEmpty && discCount > 1, input: input)
    }

    /// Disc 2, asked for (and mounted if it's an image) when `asked`, as a
    /// disc build does; `disksResolved` is published either way.
    private func resolveDisc2(of gameInfo: GameInfo, disc1: URL, asked: Bool, input: WrappBuildInput) async throws -> URL? {
        try Task.checkCancellation()
        var disc2: URL?
        if asked, let chosen = try await input.getDisk2Path(gameInfo: gameInfo, disk1: disc1) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue,
               !ISOMounter.isMacDiskImage(chosen) {
                disc2 = chosen
            } else {
                let mounted = try await isoMounter.mount(chosen)
                await bus.publishWrappBuild(.isoMounted(mounted))
                disc2 = mounted
            }
        }
        await bus.publishWrappBuild(.disksResolved(disk1: disc1, disk2: disc2))
        return disc2
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
