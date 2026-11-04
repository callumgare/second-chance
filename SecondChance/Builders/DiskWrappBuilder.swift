//
//  DiskWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from game disks (real
//  CDs, folders, or ISO images). Owns the disk flow end-to-end.
//
//  GameInfo is detected ONCE here and threaded through the rest of the
//  flow — nothing downstream re-runs detection.
//
//  Resource ownership (per the design rules): this builder mounts ISOs and
//  creates the temp wrapp, so it tears both down on the success AND error
//  paths, wrapped in do/catch.
//

import Foundation
import Logging
import GameCatalog
import SecondChanceKit
import Synchronization
import WrappBuilder

/// Builds a wrapp from game disks.
///
/// Owns the disk-specific layout (`disk-1` / `disk-2` / `disk-combined`
/// under `drive_c/nancy-drew-installer/`) and the ISO mount/unmount
/// lifecycle. Calls shared helpers (WrappBuildHelper, GameInstallerRunner)
/// for everything source-independent.
final class DiskWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameDetector: GameDetector
    private let gameInfoProvider: GameInfoProvider
    private let isoMounter: ISOMounter
    private let wineManager: WineManager
    private let updater: UpdateWrappBuilder
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.DiskWrappBuilder")

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
        updater = UpdateWrappBuilder(helper: helper, installerRunner: installerRunner, gameInfoProvider: gameInfoProvider,
                                     wineManager: wineManager, bus: bus)
    }

    // MARK: - Build Flow

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .disk))

        // A game's app chosen where its disc would go is updated from
        // itself (docs/wrapp-build.md#updating-a-wrapp): the disc source is
        // the way to it until updating is a source of its own.
        var chosen = try await input.getDisk1Path()
        if UpdateWrappBuilder.isWrapp(chosen) {
            switch try await updater.update(wrapp: chosen, input: input) {
            case .updated(let wrapp):
                return wrapp
            case .reinstallFromDisc:
                // It was up to date, and the person chose to install the
                // game again: from its disc, as any disc build.
                chosen = try await input.getDisk1Path()
                guard !UpdateWrappBuilder.isWrapp(chosen) else { throw WrappBuildError.reinstallNeedsSource(source: .disk) }
            }
        }

        // ── Resolve disk 1 and detect the game ONCE ──────────────────────
        // GameInfo threads through from here.
        let (disk1Root, _, gameInfo, installerName) = try await resolveGame(disk1: chosen, input: input)

        // ── Build ──────────────────────────────────────────────────────
        // The builder owns the temp wrapp lifecycle: removed on both the
        // success path (after the move in finalize) and on error.
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            // Each disc is copied, and the game installed from the copies.
            try await helper.ensureRoomToBuild(from: disk1Root, copies: 2 * max(gameInfo.diskCount, 1))
            // The game's bundle says what its disc edition's build runs
            // (its Wrappfile's `disc` stage); each step is run here, as the
            // disc flow always has. A plan none of whose stages has Wine
            // (a ScummVM game's disc, copied as it is) is built without it.
            guard let plan = try await Blocking.run({ try ShippedBundles.plan(forGame: gameInfo.id, edition: "cd") }) else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s disc edition names no stage")
            }
            let buildsWithWine = plan.stages.contains { $0.modules.contains(ModuleID.wine.rawValue) }
            try await helper.createBaseWrapp(at: wrappPath, composition: gameInfo.composition, buildsWithWine: buildsWithWine)
            let composition = gameInfo.composition
            // The same disc, plan and modules install the same game: a
            // build after the first clones its install (docs/wrapp-build.md#the-layer-cache).
            // On disc 1's listing alone, so a rebuild needs only disc 1.
            let key: LayerKey? = DebugSettings.shared.skipInstaller || !buildsWithWine ? nil : try await Blocking.run {
                try InstallLayer.key(slot: "\(gameInfo.id) \(plan.edition): install", plan: plan, wrappPath: wrappPath, inputs: [
                    .init("disc 1", try LayerKey.listing(of: disk1Root)),
                    .init("installer program", installerName ?? "found by name"),
                ])
            }
            let installed = try await InstallLayer(store: wineManager.layers, bus: bus).run(
                key: key, wrappPath: wrappPath, gameInfo: gameInfo, disk1: disk1Root
            ) {
                try await run(plan, wrappPath: wrappPath, disk1Root: disk1Root, gameInfo: gameInfo,
                              installerName: installerName, input: input)
            }
            try await helper.runAppSteps(plan, wrappPath: wrappPath, gameInfo: gameInfo) { name in
                switch name {
                case "disc-1": disk1Root
                case "disc-2": try await self.resolveDisk2(gameInfo: gameInfo, disk1: disk1Root, input: input)
                default: nil
                }
            }

            // Clean up unused engine unless we skipped the installer — wine
            // might be needed to run the installer later.
            if !DebugSettings.shared.skipInstaller {
                try await helper.cleanupUnusedEngine(at: wrappPath, composition: composition)
            }

            // ── Shared tail: configure → sign → save → notify ──────────────
            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: gameInfo, source: .disk,
                gameExePath: installed.gameExePath, installerDir: installed.installerDir,
                configureINI: false, launch: plan.launch, app: plan.app, input: input
            )

            // Builder-owned resources: unmount now the build is complete.
            await isoMounter.unmountAll()

            await helper.launchIfAsked(finalPath, input: input)
            return finalPath
        } catch {
            // Tear down builder-owned resources before rethrowing.
            await helper.removeTempWrapp(wrappPath)
            await isoMounter.unmountAll()

            let installError = WrappBuildError(error)
            await bus.publishWrappBuild(.failed(installError))
            throw error
        }
    }

    // MARK: - Running the plan

    /// Run the disc edition's plan's steps in the prefix: each through what
    /// has always done it — the discs copied and given drives, the
    /// installer run, each patch's steps, the games' .ini settings made. A
    /// step the disc flow can't run fails the build before anything is
    /// copied wrongly. The steps that copy into the app itself
    /// (`appSteps`) run after, outside the cached install layer, which
    /// holds the prefix alone.
    private func run(
        _ plan: BuildPlan, wrappPath: URL, disk1Root: URL, gameInfo: GameInfo,
        installerName: String?, input: WrappBuildInput
    ) async throws -> InstallLayer.Installed {
        let layout = WrappLayout(app: wrappPath)
        let composition = gameInfo.composition
        var installed: (gameExePath: String, installerDir: String)?
        var configuredINI = false

        func announceInstall() async {
            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            await bus.publishWrappBuild(.engineRouted(composition: composition, gameInfo: gameInfo))
        }

        for step in plan.bundleSteps where !WrappBuildHelper.isAppStep(step) {
            logger.debug("Plan step: \(step) (\(step.origin))")
            switch (step.module, step.instruction) {
            case ("wine", "KEEP-DISCS"):
                try checkKeptDiscs(step, gameInfo: gameInfo)
                try await copyGameDisks(
                    disk1: disk1Root,
                    to: wrappPath,
                    gameSlug: gameInfo.id,
                    disk2: { try await self.resolveDisk2(gameInfo: gameInfo, disk1: disk1Root, input: input) }
                )
            case ("installer", "RUN") where PlannedStep.input(in: step.option("from")) == "disc-1" && step.arguments.isEmpty:
                if let answerFile = step.option("answer-file") {
                    guard let file = plan.file(answerFile) else {
                        throw WrappBuildError.buildRecipeProblem("\(step.origin): the plan has no file \(answerFile)")
                    }
                    try installAnswerFile(file, into: layout.driveC.appendingPathComponent(WrappLayout.installersFolder))
                }
                await announceInstall()
                installed = try await installerRunner.installGameWithWine(
                    wrappPath: wrappPath,
                    gameInfo: gameInfo,
                    source: .disk,
                    installerName: installerName,
                    unattended: input.isUnattended,
                    chooseGameProgram: input.chooseGameProgram(among:),
                    automation: step.option("automation").flatMap(plan.file),
                    creates: try GameInstallerRunner.expectedProgram(of: step)
                )
            case _ where WineSteps.handles(step):
                try await WineSteps(bus: bus).run(step, wrappPath: wrappPath)
            case _ where GameInstallerRunner.isPatchStep(step):
                try await installerRunner.runPatchStep(step, plan: plan, wrappPath: wrappPath, gameInfo: gameInfo,
                                                       source: .disk, confirmFailure: input.confirmPatchFailure)
            case (nil, "EDIT") where step.option("from-data") == "ini":
                // The nancy-drew module's .ini settings, in the folder the
                // stage names: the game's.
                if let installed {
                    try helper.configureGameINI(in: layout.onDriveC(installed.gameExePath).deletingLastPathComponent())
                }
                configuredINI = true
            default:
                throw WrappBuildError.buildRecipeProblem("\(step.origin): the disc flow can't run \(step)")
            }
        }
        // A game whose data is copied into the app (ScummVM's) is installed
        // by its app steps, after this.
        guard let result = installed ?? (plan.stages.flatMap(\.steps).contains(where: WrappBuildHelper.isAppStep) ? ("", "") : nil) else {
            throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s disc plan installs nothing")
        }
        return InstallLayer.Installed(gameExePath: result.gameExePath, installerDir: result.installerDir, configuredINI: configuredINI)
    }

    /// Put the plan's answer file (`bundle:assets/disc.iss`) where the
    /// installer runner looks for one: `setup.iss` among the installer's discs.
    private func installAnswerFile(_ source: URL, into installers: URL) throws {
        let destination = installers.appendingPathComponent("setup.iss")
        try fileManager.createDirectory(at: installers, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        logger.notice("✅ Copied \(source.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)'s \(source.lastPathComponent) to setup.iss")
    }

    /// What `WINE.KEEP-DISCS` says, checked against what this build does
    /// with the discs: each in `C:/nancy-drew-installer/disk-<n>`, and for
    /// more than one, combined in `disk-combined` beside them.
    private func checkKeptDiscs(_ step: PlannedStep, gameInfo: GameInfo) throws {
        let into = "wine:C:/" + WrappLayout.installersFolder
        let discs = step.arguments.map(PlannedStep.input(in:))
        let expected = (1...max(gameInfo.diskCount, 1)).map { "disc-\($0)" }
        var problems: [String] = []
        if step.option("into") != into { problems.append("--into=\(step.option("into") ?? "") (it keeps them in \(into))") }
        if discs != expected { problems.append("\(step.arguments.joined(separator: " ")) (it keeps \(expected.joined(separator: ", ")))") }
        let combined = gameInfo.diskCount > 1 ? into + "/disk-combined" : nil
        if step.option("combined") != combined {
            problems.append("--combined=\(step.option("combined") ?? "") (it combines \(combined.map { "them in \($0)" } ?? "nothing"))")
        }
        guard problems.isEmpty else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): this build can't do what WINE.KEEP-DISCS says: \(problems.joined(separator: "; "))")
        }
    }

    /// Disc 2 of a two-disc game, mounted if it's an ISO, or nil for a
    /// one-disc game. Publishes `disksResolved` either way.
    private func resolveDisk2(gameInfo: GameInfo, disk1: URL, input: WrappBuildInput) async throws -> URL? {
        // Not worth asking for disc 2 of a build that has been cancelled.
        try Task.checkCancellation()
        var disk2Root: URL?
        if gameInfo.diskCount > 1, let disk2 = try await input.getDisk2Path(gameInfo: gameInfo, disk1: disk1) {
            logger.notice("Disk 2: \(disk2.path)")
            if let mounted = try await mountIfImage(disk2) {
                await bus.publishWrappBuild(.isoMounted(mounted))
                disk2Root = mounted
            } else {
                disk2Root = disk2
            }
        }
        await bus.publishWrappBuild(.disksResolved(disk1: disk1, disk2: disk2Root))
        return disk2Root
    }

    /// Disk 1, mounted if it's an image, the game on it, and the program to
    /// install it with when that isn't an installer by name (nil when it is,
    /// or the game needs no installer). A disc whose game or installer isn't
    /// recognised can be swapped for another, which is then detected in turn;
    /// an installed game chosen instead of a disc is turned down. Everything
    /// from the first mount to the temp wrapp: a failure here (an unreadable
    /// disc, the wrong game) still unmounts what it mounted and reports
    /// itself, like a failure in the build.
    private func resolveGame(
        disk1 chosen: URL, input: WrappBuildInput
    ) async throws -> (disk1Root: URL, gameSlug: String, gameInfo: GameInfo, installerName: String?) {
        // A link followed: an installed game's folder is one when Steam or
        // Big Fish installed it (`--into`), and listing a folder through a
        // link fails as not a folder.
        var disk1 = chosen.resolvingSymlinksInPath()
        do {
            while true {
                logger.notice("Disk 1: \(disk1.path)")
                let disk1Mounted = try await mountIfImage(disk1)
                if let mounted = disk1Mounted {
                    await bus.publishWrappBuild(.isoMounted(mounted))
                }
                let disk1Root = disk1Mounted ?? disk1

                await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
                // Before detection, so an installed game whose folder name
                // doesn't say which it is isn't asked about as unrecognised.
                if try GameDetector.isInstalledGame(at: disk1Root, games: gameInfoProvider.allGames()) {
                    throw WrappBuildError.installedGameNotInstaller
                }
                let gameSlug = try await gameDetector.detectGame(fromDisk: disk1Root)
                let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
                logger.notice("Detected game: \(gameInfo.title)")
                if gameInfo.id == GameInfo.unknownGame.id,
                   try await input.askAboutUnrecognisedGame(.disk) == .chooseAnother {
                    await isoMounter.unmountAll()
                    disk1 = try await input.getDisk1Path()
                    continue
                }
                // Asked about before the disc is copied, so choosing another
                // costs nothing. ScummVM runs a game from the disc's files.
                var installerName: String?
                if gameInfo.composition.launcher == .wine {
                    switch try GameDetector.installerLookup(in: disk1Root) {
                    case .recognised:
                        break
                    case .none:
                        throw WrappBuildError.installerNotFound
                    case .unrecognised(let programs):
                        switch try await input.askAboutUnidentifiedInstaller(programs: programs) {
                        case .tryProgram(let program):
                            installerName = program
                        case .chooseAnother:
                            await isoMounter.unmountAll()
                            disk1 = try await input.getDisk1Path()
                            continue
                        }
                    }
                }
                await bus.publishWrappBuild(.gameDetected(gameInfo))
                try await input.onGameDetected(gameInfo)
                return (disk1Root, gameSlug, gameInfo, installerName)
            }
        } catch {
            await isoMounter.unmountAll()
            let buildError = WrappBuildError(error)
            await bus.publishWrappBuild(.failed(buildError))
            throw error
        }
    }

    // MARK: - ISO Lifecycle (builder-owned)

    /// Mount the given disk if it's a file, a disc image whatever its name.
    /// Returns the mount point, or nil when the path was already a folder.
    /// The disc picker takes only `.iso` files, but what counts as one is up
    /// to the apps on the Mac, and another app can claim other names for it.
    private func mountIfImage(_ disk: URL) async throws -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: disk.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return try await isoMounter.mount(disk)
    }

    // MARK: - Disk Layout (disk-specific; not shared with other sources)

    private let fileManager = FileManager.default
    private let cacheManager = CacheManager.shared

    /// Copy game installer disks into the wrapp: disk-1, optional disk-2,
    /// and the disk-combined symlink view for multi-disk games. Mounts the
    /// disk directories as Wine CD-ROM drives. `disk2` is called once disk 1
    /// has been copied, and gives disk 2 or nil.
    private func copyGameDisks(
        disk1: URL,
        to wrappPath: URL,
        gameSlug: String,
        disk2 resolveDisk2: () async throws -> URL?
    ) async throws {
        // Check cache first
        if let metadata = try cacheManager.restoreCache(stage: .diskGameInstallerCopied, to: wrappPath) {
            if metadata.gameSlug == gameSlug {
                await bus.publishWrappBuild(.disksResolved(disk1: disk1, disk2: nil))
                return
            } else {
                throw WrappBuildError.cachedGameMismatch
            }
        }

        await bus.publishWrappBuild(.progress(.copyingInstaller(substep: nil)))

        let driveCPath = WrappLayout(app: wrappPath).driveC
        let installerPath = driveCPath.appendingPathComponent(WrappLayout.installersFolder)

        try fileManager.createDirectory(at: installerPath, withIntermediateDirectories: true)

        // Wine is told the discs' drives are CD drives while they copy: each
        // run of Wine starts its session afresh, which on its own took 8 to
        // 18 s per drive once the copying was done.
        let letters = (0..<max(1, gameInfoProvider.gameInfo(for: gameSlug).diskCount)).map(Self.driveLetter(forDisc:))
        let marking = DriveMarking(wine: Wine(wrapp: wrappPath), letters: letters)

        let disk1Dest = installerPath.appendingPathComponent("disk-1")
        do {
            try await copyDiscs(disk1: disk1, disk1Dest: disk1Dest, into: installerPath, disk2: resolveDisk2)
        } catch {
            // Not left running in the prefix the builder is about to remove.
            await marking.cancel()
            throw error
        }
        if !marking.isFinished {
            await bus.publishWrappBuild(.progress(.copyingInstaller(substep: String(localized: "Getting the discs ready"))))
        }
        try await marking.wait()

        // Mount the disk directories as CD-ROM drives
        // (Don't report progress again - would cause duplicate print)
        try mountGameDisksIntoWine(wrappPath: wrappPath)

        // Save to cache
        try cacheManager.saveCache(wrappPath: wrappPath, stage: .diskGameInstallerCopied, gameSlug: gameSlug)
    }

    /// Copy disc 1, and disc 2 if the game has one, the second into a
    /// folder of its own with `disk-combined` linking to both.
    private func copyDiscs(disk1: URL, disk1Dest: URL, into installerPath: URL, disk2 resolveDisk2: () async throws -> URL?) async throws {
        try await copyDisc(disk1, to: disk1Dest)

        // Copy disk 2 if present
        if let disk2 = try await resolveDisk2() {
            await bus.publishWrappBuild(.progress(.copyingInstaller(substep: String(localized: "Copying disc 2"))))
            let disk2Dest = installerPath.appendingPathComponent("disk-2")
            try await copyDisc(disk2, to: disk2Dest)

            // Create combined disk directory with symlinks
            let combinedDest = installerPath.appendingPathComponent("disk-combined")
            try fileManager.createDirectory(at: combinedDest, withIntermediateDirectories: true)

            // Symlink contents from both disks
            let disksToLink = [disk1Dest, disk2Dest]
            for diskDest in disksToLink {
                let diskName = diskDest.lastPathComponent
                let diskContents = try fileManager.contentsOfDirectory(at: diskDest, includingPropertiesForKeys: nil)
                for item in diskContents {
                    let fileName = item.lastPathComponent

                    // Skip .DS_Store files - codesign will fail if it tries to sign a .DS_Store symlink
                    if fileName == ".DS_Store" {
                        continue
                    }

                    let linkPath = combinedDest.appendingPathComponent(fileName)
                    // Don't overwrite existing links (disk-1 has priority)
                    if !fileManager.fileExists(atPath: linkPath.path) {
                        let relativePath = "../\(diskName)/\(fileName)"
                        try fileManager.createSymbolicLink(atPath: linkPath.path, withDestinationPath: relativePath)
                    }
                }
            }
        }
    }

    /// The drive letter disc `index` (from 0) is at: D: on.
    static func driveLetter(forDisc index: Int) -> Character {
        Character(UnicodeScalar(UInt8(100 + index)))  // "d" is 100
    }

    /// Marking the discs' drive letters as CD drives (`WineDrives.setKind`),
    /// run alongside copying the discs.
    private struct DriveMarking {
        /// Set once the marking is done, so the copy can tell whether
        /// there's still a wait to name.
        private final class Done: Sendable {
            private let value = Mutex(false)
            var isSet: Bool { value.withLock { $0 } }
            func set() { value.withLock { $0 = true } }
        }

        private let task: Task<Void, Error>
        private let done = Done()

        init(wine: Wine, letters: [Character]) {
            let done = done
            task = Task {
                try await wine.drives.setKind(.cdrom, of: letters)
                done.set()
            }
        }

        var isFinished: Bool { done.isSet }
        func wait() async throws { try await task.value }
        func cancel() async {
            task.cancel()
            _ = try? await task.value
        }
    }

    /// Mount game disk directories as CD-ROM drives.
    ///
    /// The copies stay in the wrapp after the install, still mounted, for the
    /// game as well as its installer: some games check their disc is in the
    /// drive before they will play. We don't know which files each one looks
    /// at, so the whole disc is kept rather than just what the check reads.
    /// A ScummVM game needs them anyway, as its game data. That the letters
    /// are CD drives was set while the discs copied (`DriveMarking`).
    private func mountGameDisksIntoWine(wrappPath: URL) throws {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let installerPath = driveCPath.appendingPathComponent(WrappLayout.installersFolder)

        // Find all disk-* directories and sort them
        guard let contents = try? fileManager.contentsOfDirectory(at: installerPath, includingPropertiesForKeys: [.isDirectoryKey]) else {
            logger.notice("No installer directory found, skipping disk mounting")
            return
        }

        var diskDirs: [(number: Int, url: URL)] = []
        for item in contents {
            let name = item.lastPathComponent
            if name.hasPrefix("disk-"),
               let diskNumber = Int(name.dropFirst(5)) { // Skip "disk-"
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    diskDirs.append((number: diskNumber, url: item))
                }
            }
        }

        diskDirs.sort { $0.number < $1.number }

        if diskDirs.isEmpty {
            logger.notice("No disk directories found to mount")
            return
        }

        logger.notice("Found \(diskDirs.count) disk director\(diskDirs.count == 1 ? "y" : "ies") to mount as CD-ROM drives")

        // Mount each disk starting at drive letter "d:"
        for (index, disk) in diskDirs.enumerated() {
            guard index < 23 else {
                logger.warning("Warning: Too many disks to mount (maximum 23)")
                break
            }
            let letter = Self.driveLetter(forDisc: index)

            // Use relative path from prefix directory
            let relativePath = "../drive_c/nancy-drew-installer/disk-\(disk.number)"

            logger.notice("Mounting disk-\(disk.number) as \(letter): (cdrom)")
            try Wine(wrapp: wrappPath).drives.mount(relativePath, as: letter)
        }
    }

    /// Give the owner write permission throughout a copied disc. A CD's
    /// directories are read-only and a copy keeps that, so nothing could
    /// delete the copy afterwards: not a failed build's cleanup, not the
    /// integration test's, and not a user deleting the wrapp. Each such copy
    /// left behind is gigabytes, and they had filled a test machine's disk.
    /// Copy a disc into the wrapp (`DiscCopy`): contents only, writable,
    /// cancellable, with how much is done on the progress screen.
    private func copyDisc(_ disc: URL, to destination: URL) async throws {
        let total = await Blocking.run { FreeSpace.size(of: disc) }
        logger.notice("Copying \(disc.path) (\(total.map(FreeSpace.describe) ?? "size unknown"))")
        let bus = bus
        try await DiscCopy.copy(from: disc, to: destination, total: total) { progress in
            let copied = FreeSpace.describe(progress.copied)
            let measured = StepProgress(
                fraction: progress.total.map { min(1, Double(progress.copied) / Double(max($0, 1))) },
                text: progress.total.map { "\(copied) of \(FreeSpace.describe($0))" } ?? "\(copied) copied"
            )
            Task { await bus.publishWrappBuild(.stepProgress(measured)) }
        }
        // The total is how full the disc is, which counts its file system as
        // well as its files: done, the bar is full rather than just short.
        if let total {
            let all = FreeSpace.describe(total)
            await bus.publishWrappBuild(.stepProgress(StepProgress(fraction: 1, text: "\(all) of \(all)")))
        }
    }
}
