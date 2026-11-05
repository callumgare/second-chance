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
        updater = UpdateWrappBuilder(helper: helper, installerRunner: installerRunner, gameInfoProvider: gameInfoProvider, bus: bus)
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
        // Each stage in a tree of its own in a working folder the builder
        // owns: removed on both the success path (after the move in
        // finalize) and on error.
        let folder = helper.createBuildFolder()
        logger.notice("Working folder: \(folder.path)")
        await bus.publishWrappBuild(.wrappStarted(path: folder))

        do {
            // Each disc is copied, and the game installed from the copies.
            try await helper.ensureRoomToBuild(from: disk1Root, copies: 2 * max(gameInfo.diskCount, 1))
            let edition = try await Blocking.run { try ShippedBundles.edition(ofGame: gameInfo.id, source: .disk) }
            guard let plan = try await Blocking.run({ try ShippedBundles.plan(forGame: gameInfo.id, edition: edition) }),
                  let launch = plan.launch else {
                throw WrappBuildError.buildRecipeProblem("\(gameInfo.id)'s disc edition names no stage")
            }
            let template = try await helper.template()
            await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))
            await bus.publishWrappBuild(.engineRouted(composition: gameInfo.composition, gameInfo: gameInfo))

            // The plan, carried out by the runner: the discs through the disc
            // module's inputs, disc 2 asked for when a step needs it.
            let inputs = DiscInputs(disc1: disk1Root, diskCount: gameInfo.diskCount) { [self] in
                try await self.resolveDisk2(gameInfo: gameInfo, disk1: disk1Root, input: input)
            }
            let installer = InstallerExecutor(runner: installerRunner, gameInfo: gameInfo, source: .disk,
                                              installerName: installerName, input: input)
            let (configuration, emitter) = AppRunner.configuration(bus: bus, input: input, game: gameInfo, inputs: inputs,
                                                                   downloader: DownloadWrappBuilder.standardDownloader(), helper: helper,
                                                                   executors: ["installer": installer])
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
            try await Blocking.run { try WrappAssembler.layIn(template, into: wrappPath) }
            if launch.launcher() == .scummvm {
                await bus.publishWrappBuild(.gameExeDetected(path: "/SharedSupport/game", gameInfo: gameInfo))
            } else if !installer.installed {
                // An install restored from a layer, which never said.
                await bus.publishWrappBuild(.gameExeDetected(path: String(launch.path.dropFirst(2)), gameInfo: gameInfo))
            }

            // ── Shared tail: configure → sign → save → notify ──────────────
            // The settings' older keys, from the recorded launch.
            let inPrefix = launch.launcher() != .scummvm
            let gameExePath = inPrefix ? String(launch.path.dropFirst(2)) : ""
            let installerDir = inPrefix ? installerRunner.installerDirectoryPath(in: WrappLayout(app: wrappPath).driveC) : ""
            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: gameInfo, source: .disk,
                gameExePath: gameExePath, installerDir: installerDir,
                edition: edition, launch: launch, app: plan.app, input: input
            )

            // Builder-owned resources: unmount now the build is complete.
            await isoMounter.unmountAll()
            await helper.removeTempWrapp(folder)

            await helper.launchIfAsked(finalPath, input: input)
            return finalPath
        } catch {
            // Tear down builder-owned resources before rethrowing.
            await helper.removeFailedBuild(folder)
            await isoMounter.unmountAll()

            let installError = WrappBuildError(error)
            await bus.publishWrappBuild(.failed(installError))
            throw error
        }
    }

    // MARK: - Discs

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
}
