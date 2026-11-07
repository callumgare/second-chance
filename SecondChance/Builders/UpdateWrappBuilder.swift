//
//  UpdateWrappBuilder.swift
//  SecondChance
//
//  Brings a wrapp built by an older Second Chance up to this one, from the
//  wrapp itself rather than the disc: reached through the disc source for
//  now, by choosing the game's app where its disc would go.
//
//  Resource ownership: this builder creates the working folder its plans'
//  trees are in, so it removes it on the success AND error paths. The old
//  wrapp is only read; saving the new one may replace it, as saving any
//  rebuild does.
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
/// old app's prefix, game and all, is the `previous` input of plans the
/// runner carries out (decision 21 of the builders plan): this Second
/// Chance's engines and the wine module's update stage, then each of the
/// bundle's update stages. The template is laid in, and it is finished as
/// every build is. One that can only be built afresh is turned down,
/// saying the disc is needed.
final class UpdateWrappBuilder {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameInfoProvider: GameInfoProvider
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.UpdateWrappBuilder")

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameInfoProvider = gameInfoProvider
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

        // Each plan in a tree of its own in a working folder the builder
        // owns, built from the last one's (`FROM ${input.previous}`), the
        // first from the old app's prefix: removed on both paths.
        let folder = helper.createBuildFolder()
        logger.notice("Working folder: \(folder.path)")
        await bus.publishWrappBuild(.wrappStarted(path: folder))
        do {
            try await helper.ensureRoomToBuild(from: WrappLayout(app: old).prefix, copies: 2)
            let template = try await helper.template()
            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            await bus.publishWrappBuild(.engineRouted(composition: composition, gameInfo: gameInfo))
            var previous = folder.appendingPathComponent("previous.app")
            try await carryOver(from: old, into: previous, composition: composition)

            let plans = try await updatePlans(chain, edition: lock.edition, gameInfo: gameInfo, composition: composition)
            for (index, plan) in plans.enumerated() {
                try Self.checkNeedsNoSource(plan, source: source)
                let installer = InstallerExecutor(runner: installerRunner, gameInfo: gameInfo, source: source, installerName: nil, input: input)
                let (configuration, emitter) = AppRunner.configuration(
                    bus: bus, input: input, game: gameInfo, inputs: GivenInputs(["previous": previous]),
                    downloader: DownloadWrappBuilder.standardDownloader(), helper: helper, executors: ["installer": installer])
                do {
                    previous = try await PlanRunner(plan: plan, configuration: configuration)
                        .build(in: folder.appendingPathComponent("update-\(index + 1)"))
                } catch let error as StepFailure {
                    await emitter.finish()
                    throw WrappBuildError(stepFailure: error)
                } catch {
                    await emitter.finish()
                    throw error
                }
                await emitter.finish()
            }
            let wrappPath = previous
            try await Blocking.run { try WrappAssembler.layIn(template, into: wrappPath) }

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
            // A ScummVM game's old prefix, which nothing runs now.
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
            await helper.removeTempWrapp(folder)
            await helper.launchIfAsked(finalPath, input: input)
            return .updated(finalPath)
        } catch {
            await helper.removeFailedBuild(folder)
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }
    }

    // MARK: - Plans

    /// What the chain runs, as plans, in order (decision 21 of the builders
    /// plan): first the engines and the modules' own updates (the wine
    /// module's update stage, which a Wine move needs too), then each of the
    /// bundle's update stages, every one with the updates applied and what
    /// the old app recorded.
    private func updatePlans(_ chain: UpdatePlanner.Chain, edition: String, gameInfo: GameInfo,
                             composition: Composition) async throws -> [BuildPlan] {
        let slug = gameInfo.id
        let wineMoved = chain.moves.contains { $0.module == "wine" } && composition.has(.wine)
        var wineUpdate = wineMoved
        var stages: [(stage: String, updates: [String])] = []
        for step in chain.steps {
            switch step {
            case .module("wine", "wine-prefix"):
                wineUpdate = true
            case .module(let module, let update):
                throw WrappBuildError.buildRecipeProblem("the \(module) module's \(update) update has no stage to run it")
            case .stage(let stage, let updates):
                stages.append((stage, updates))
            }
        }
        let modules = composition.modules.map(\.rawValue)
        let applied = chain.applied, previous = chain.previous
        let wine = wineUpdate, stageUpdates = stages
        return try await Blocking.run {
            var plans = [try ShippedBundles.updatePlan(forGame: slug, edition: edition, wineUpdate: wine && modules.contains("wine"),
                                                       wineMoved: wineMoved, modules: modules, updates: applied, previous: previous)]
            for (stage, updates) in stageUpdates {
                let plan = try ShippedBundles.plan(forGame: slug, edition: edition, stage: stage, updates: applied, previous: previous)
                guard plan.stages.contains(where: { $0.from == .input("previous") }) else {
                    throw WrappBuildError.buildRecipeProblem("\(stage), the \(updates.joined(separator: ", ")) update, isn't built FROM ${input.previous}")
                }
                plans.append(plan)
            }
            return plans
        }
    }

    /// An update whose steps read the edition's source (a disc, a download)
    /// installs the game again, which only a fresh build from it can.
    nonisolated static func checkNeedsNoSource(_ plan: BuildPlan, source: WrappSource) throws {
        for step in plan.stages.flatMap(\.steps) {
            let words = step.arguments + step.options.values.flatMap { $0 }
            if let input = words.lazy.compactMap(PlannedStep.input(in:)).first {
                throw WrappBuildError.updateNeedsSource(reason: "\(step.origin) reads \(input)", source: source)
            }
        }
    }

    // MARK: - Old apps

    /// An old ScummVM app's data, which it kept in its prefix (its
    /// settings' `GameInstallerDir`), moved to where the launch reads it
    /// (`/SharedSupport/game/`). The prefix then goes with the rest of
    /// Wine, as the app's launch has none.
    private func moveScummVMData(of settings: WrappSettings, to launch: RecordedLaunch, in wrappPath: URL) async throws {
        let layout = WrappLayout(app: wrappPath)
        let data = layout.onDriveC(settings.installerDir)
        guard let destination = layout.location(launch.program, places: helper.places) else {
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
            guard let file = plan.file(step.arguments[0]), let destination = layout.location(step.arguments[1], places: helper.places) else { continue }
            try helper.copyFile(file, to: destination)
        }
    }

    /// The old app made into a tree: its prefix, game and all, with the
    /// person's files left behind. Its Documents and A: drive lead to their
    /// saves, which nothing an update runs may touch, so both are pointed
    /// at an empty stand-in until the app's first launch points them back.
    /// The rest of the old app (its launcher, its engines) is this Second
    /// Chance's once the plans and the template are laid in.
    private func carryOver(from old: URL, into tree: URL, composition: Composition) async throws {
        let from = WrappLayout(app: old).prefix, to = WrappLayout(app: tree).prefix
        try await Blocking.run {
            let files = FileManager.default
            if files.fileExists(atPath: tree.path) { try files.removeItem(at: tree) }
            try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A clone on the same volume, so even a big game takes moments.
            try files.copyItem(at: from, to: to)
        }
        guard composition.has(.wine) else { return }
        let wine = Wine(wrapp: tree)
        // In the working folder, which goes with the build.
        let standIn = tree.deletingLastPathComponent().appendingPathComponent("saves-stand-in", isDirectory: true)
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: true)
        try wine.drives.mount(standIn, as: "a")
        try? FileManager.default.removeItem(at: wine.documents)
        try FileManager.default.createSymbolicLink(at: wine.documents, withDestinationURL: standIn)
        logger.notice("[Update] Carried the game over from the old app, with its saves left where they are")
    }
}
