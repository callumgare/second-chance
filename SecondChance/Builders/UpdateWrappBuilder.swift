//
//  UpdateWrappBuilder.swift
//  SecondChance
//
//  Brings a wrapp built by an older Second Chance up to this one, from the
//  wrapp itself rather than the disc: reached through the disc source for
//  now, by choosing the game's app where its disc would go.
//
//  Resource ownership: this builder creates the temp wrapp, so it removes
//  it on the success AND error paths. The old wrapp is only read; saving
//  the new one may replace it, as saving any rebuild does.
//

import Foundation
import Logging
import GameCatalog
import SecondChanceKit
import WrappBuilder

/// Updates an existing wrapp (docs/wrapp-build.md#updating-a-wrapp): the
/// old wrapp's lock, or one made up for a wrapp from before locks, says
/// what it was built from; the bundle's and modules' updates say how to
/// bring it here (`UpdatePlanner`), worked out before anything runs. The
/// game installed in the old wrapp is carried into a wrapp made from this
/// Second Chance's template, the updates run over it, and it is finished
/// as every build is. One that can only be built afresh is turned down,
/// saying the disc is needed.
final class UpdateWrappBuilder {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameInfoProvider: GameInfoProvider
    private let wineManager: WineManager
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.UpdateWrappBuilder")

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        wineManager: WineManager = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameInfoProvider = gameInfoProvider
        self.wineManager = wineManager
        self.bus = bus
    }

    /// Whether `url` is a game's app Second Chance made, rather than a disc.
    nonisolated static func isWrapp(_ url: URL) -> Bool {
        url.pathExtension == "app" && FileManager.default.fileExists(atPath: WrappLayout(app: url).settingsFile.path)
    }

    /// What the old wrapp at `url` was built from: its lock, or one made up
    /// from its settings for a wrapp from before locks.
    nonisolated static func lock(of url: URL) throws -> (lock: WrappLock, settings: WrappSettings) {
        let layout = WrappLayout(app: url)
        let settings = try WrappSettings(of: layout)
        if let lock = try WrappLock(of: layout) { return (lock, settings) }
        guard let slug = settings.gameSlug else {
            throw WrappBuildError.updateNeedsSource(reason: "its settings don't say which game it is")
        }
        let wineVersion = (try? String(contentsOf: layout.wine.appendingPathComponent("version"), encoding: .utf8))
            .flatMap(WrappLock.wineVersion(fromVersionFile:))
        // The oldest wrapps never recorded their source: discs were all
        // there was.
        let edition = WrappBuildHelper.edition(of: settings.source ?? .disk)
        return (WrappLock.madeUp(settings: settings, program: "nancy-drew/" + slug, edition: edition, wineVersion: wineVersion), settings)
    }

    /// How an update ended: the updated wrapp, or the person choosing to
    /// install the game again from its disc, as the app had nothing to
    /// update.
    enum Outcome {
        case updated(URL)
        case reinstallFromDisc
    }

    func update(wrapp old: URL, input: WrappBuildInput) async throws -> Outcome {
        logger.notice("Updating the game's app: \(old.path)")
        await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
        let (lock, settings) = try await Blocking.run { try Self.lock(of: old) }
        logger.notice("It was built from \(lock.summary)\(lock.madeUp == true ? " (made up from its settings: it has no lock)" : "")")
        guard let slug = settings.gameSlug else { throw WrappBuildError.updateNeedsSource(reason: "it doesn't say which game it is") }
        let gameInfo = gameInfoProvider.gameInfo(for: slug)
        await bus.publishWrappBuild(.gameDetected(gameInfo))
        try await input.onGameDetected(gameInfo)

        let source = settings.source ?? .disk
        let composition = settings.composition
        let (decision, target) = try await Blocking.run {
            try ShippedBundles.updateDecision(from: lock, forGame: slug, source: source, composition: composition)
        }
        let chain: UpdatePlanner.Chain
        switch decision {
        case .update(let planned):
            chain = planned
        case .freshBuild(let reason):
            logger.notice("It can't be updated, only built afresh: \(reason)")
            throw WrappBuildError.updateNeedsSource(reason: reason, source: source)
        case .upToDate:
            logger.notice("It is already up to date: no update applies, and it has this Second Chance's launcher and engines")
            try await input.confirmReinstall(gameInfo, source: source)
            logger.notice("Installing it again from the start, as asked")
            guard source == .disk else { throw WrappBuildError.reinstallNeedsSource(source: source) }
            return .reinstallFromDisc
        }
        let applied = chain.applied.isEmpty ? "nothing but this Second Chance's own app" : chain.applied.joined(separator: ", ")
        let moves = chain.moves.map { ", moving \($0.module) from \($0.from) to \($0.to)" }.joined()
        logger.notice("Updating it with \(applied)\(moves)")

        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")
        do {
            try await helper.ensureRoomToBuild(from: WrappLayout(app: old).prefix, copies: 1)
            try await helper.createBaseWrapp(at: wrappPath, composition: composition, buildsWithWine: composition.has(.wine))
            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            await bus.publishWrappBuild(.engineRouted(composition: composition, gameInfo: gameInfo))
            try await carryOver(from: old, into: wrappPath, composition: composition)

            for move in chain.moves where move.module == "wine" {
                logger.notice("Moving the prefix from Wine \(move.from) to \(move.to)")
                await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: String(localized: "Updating the game's Windows files"))))
                try await wineManager.movePrefix(at: wrappPath)
            }
            for step in chain.steps {
                try await run(step, chain: chain, edition: lock.edition, wrappPath: wrappPath, gameInfo: gameInfo,
                              settings: settings, source: source, input: input)
            }
            // What this bundle's edition records: its launch and its icon. A
            // ScummVM game's data, which old apps kept in their prefix, moves
            // into the app where the launch reads it.
            let editionID = target.edition
            let editionPlan = try await Blocking.run { try ShippedBundles.plan(forGame: gameInfo.id, edition: editionID) }
            var gameExePath = settings.gameExePath, installerDir = settings.installerDir
            if let launch = editionPlan?.launch, launch.launcher() == .scummvm, settings.recordedLaunch == nil {
                try await moveScummVMData(of: settings, to: launch, in: wrappPath)
                gameExePath = ""
                installerDir = ""
            }
            if let editionPlan {
                try await runFileCopies(editionPlan, wrappPath: wrappPath)
            }
            try await helper.cleanupUnusedEngine(at: wrappPath, composition: composition)

            let record = WrappLock.UpdateRecord(fromBundle: lock.bundle.version, fromModules: lock.modules,
                                                applied: chain.applied, fromBuiltBy: lock.builtBy)
            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: gameInfo, source: source,
                gameExePath: gameExePath, installerDir: installerDir,
                steamID: settings.steamAppID, composition: composition, steamLaunchMode: settings.steamLaunchMode,
                edition: target.edition, updated: record, launch: editionPlan?.launch ?? settings.recordedLaunch,
                app: editionPlan?.app ?? RecordedApp(), input: input
            )
            await helper.launchIfAsked(finalPath, input: input)
            return .updated(finalPath)
        } catch {
            await helper.removeTempWrapp(wrappPath)
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }
    }

    // MARK: - Steps

    /// An old ScummVM app's data, which it kept in its prefix (its
    /// settings' `GameInstallerDir`), moved to where the launch reads it
    /// (`/SharedSupport/game/`). The prefix then goes with the rest of
    /// Wine, as the app's launch has none.
    private func moveScummVMData(of settings: WrappSettings, to launch: RecordedLaunch, in wrappPath: URL) async throws {
        let layout = WrappLayout(app: wrappPath)
        let data = layout.onDriveC(settings.installerDir)
        guard let destination = layout.location(launch.path) else {
            throw WrappBuildError.buildRecipeProblem("the launch's \(launch.path) has no place in the app")
        }
        guard FileManager.default.fileExists(atPath: data.path) else {
            throw WrappBuildError.buildRecipeProblem("the old app's game data isn't at \(settings.installerDir)")
        }
        try await Blocking.run {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            // A disc's data folder may be a link to the discs' combined view.
            try FileManager.default.copyItem(at: data.resolvingSymlinksInPath(), to: destination)
        }
        logger.notice("[Update] Moved the game's data from \(settings.installerDir) to \(launch.path)")
    }

    /// The plan's copies of a bundle's or module's files into the app (its
    /// icon), which an update brings as a build does.
    private func runFileCopies(_ plan: BuildPlan, wrappPath: URL) async throws {
        let layout = WrappLayout(app: wrappPath)
        for step in plan.stages.flatMap(\.steps) where WrappBuildHelper.isAppStep(step) && step.option("from") == nil {
            guard let file = plan.file(step.arguments[0]), let destination = layout.location(step.arguments[1]) else { continue }
            try helper.copyFile(file, to: destination)
        }
    }

    /// The old wrapp's prefix, game and all, in place of the new one's, with
    /// the person's files left behind: its Documents and A: drive lead to
    /// their saves, which nothing an update runs may touch, so both are
    /// pointed at an empty stand-in until the wrapp's first launch points
    /// them back. Z: comes back for the update's own Wine programs, and is
    /// taken away again as the wrapp is finished.
    private func carryOver(from old: URL, into wrappPath: URL, composition: Composition) async throws {
        let from = WrappLayout(app: old).prefix, to = WrappLayout(app: wrappPath).prefix
        try await Blocking.run {
            let files = FileManager.default
            if files.fileExists(atPath: to.path) { try files.removeItem(at: to) }
            // A clone on the same volume, so even a big game takes moments.
            try files.copyItem(at: from, to: to)
        }
        guard composition.has(.wine) else { return }
        let wine = Wine(wrapp: wrappPath)
        let standIn = URL(fileURLWithPath: "/tmp/second-chance-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: true)
        try wine.drives.mount(standIn, as: "a")
        try? FileManager.default.removeItem(at: wine.documents)
        try FileManager.default.createSymbolicLink(at: wine.documents, withDestinationURL: standIn)
        try wine.drives.mount("/", as: "z")
        logger.notice("[Update] Carried the game over from the old app, with its saves left where they are")
    }

    private func run(_ step: UpdatePlanner.Step, chain: UpdatePlanner.Chain, edition: String, wrappPath: URL,
                     gameInfo: GameInfo, settings: WrappSettings, source: WrappSource, input: WrappBuildInput) async throws {
        switch step {
        case .module("wine", let update) where update == "wine-prefix":
            // The prefix stage's steps over the old prefix, with the game left
            // installed; and for a DirectDraw game, its cnc-ddraw steps too,
            // which the shared prefix no longer has.
            logger.notice("[Update] \(update): running the wine module's prefix stage over the game's prefix")
            try await wineManager.runPrefixStage(at: wrappPath, bus: bus)
            let slug = gameInfo.id
            let cncDdraw = try await Blocking.run {
                (try ShippedBundles.plan(forGame: slug, edition: edition)?.bundleSteps ?? []).filter { step in
                    step.origin.hasPrefix("wine/functions/cnc-ddraw")
                }
            }
            for step in cncDdraw {
                try await WineSteps(bus: bus).run(step, wrappPath: wrappPath)
            }
        case .module(let module, let update):
            throw WrappBuildError.buildRecipeProblem("the \(module) module's \(update) update has no Swift to run it")
        case .stage(let stage, let updates):
            let slug = gameInfo.id
            let plan = try await Blocking.run {
                try ShippedBundles.plan(forGame: slug, edition: edition, stage: stage, updates: chain.applied, previous: chain.previous)
            }
            logger.notice("[Update] \(updates.joined(separator: ", ")): running the \(stage) stage")
            try await run(plan, wrappPath: wrappPath, gameInfo: gameInfo, settings: settings, source: source, input: input)
        }
    }

    /// An update stage's steps, as the disc flow runs the same steps: the
    /// game's patches and its .ini settings, over the installed game. A step
    /// that needs the disc, or that this can't run yet, fails before it
    /// changes anything wrongly.
    private func run(_ plan: BuildPlan, wrappPath: URL, gameInfo: GameInfo, settings: WrappSettings,
                     source: WrappSource, input: WrappBuildInput) async throws {
        let layout = WrappLayout(app: wrappPath)
        let gameDir = gameInfo.composition.launcher == .scummvm
            ? layout.onDriveC(settings.installerDir)
            : layout.onDriveC(settings.gameExePath).deletingLastPathComponent()
        for step in plan.bundleSteps {
            logger.debug("Update step: \(step) (\(step.origin))")
            switch (step.module, step.instruction) {
            case _ where WineSteps.handles(step):
                try await WineSteps(bus: bus).run(step, wrappPath: wrappPath)
            case _ where GameInstallerRunner.isPatchStep(step):
                try await installerRunner.runPatchStep(step, plan: plan, wrappPath: wrappPath, gameInfo: gameInfo,
                                                       source: source, confirmFailure: input.confirmPatchFailure)
            case (nil, "EDIT") where step.option("from-data") == "ini":
                if gameInfo.composition.launcher != .scummvm { try helper.configureGameINI(in: gameDir) }
            case ("wine", "KEEP-DISCS"), ("installer", "RUN"), ("her-download", "INSTALL"):
                throw WrappBuildError.updateNeedsSource(reason: "\(step.origin) installs the game again", source: source)
            default:
                throw WrappBuildError.buildRecipeProblem("\(step.origin): an update can't run \(step) yet")
            }
        }
    }
}
