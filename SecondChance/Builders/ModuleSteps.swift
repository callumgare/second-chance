//
//  ModuleSteps.swift
//  SecondChance
//
//  The steps a builder that carries out its plan itself hands to the
//  modules' executors: until every source builds through the runner.

import BasiliskExecutor
import Foundation
import Logging
import NancyDrewExecutor
import ScummVMExecutor
import SecondChanceKit
import WineExecutor
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ModuleSteps")

/// Carries out, through the runner and the modules' executors, the steps
/// today's builders don't carry out themselves: the wine module's `DRIVES`,
/// `REGISTRY`, `WINETRICKS` and `MOUNT`, the core's `EDIT --ini`, and
/// `NANCY-DREW.CONFIGURE-INI`. Each step's `--progress` names the text the
/// build shows meanwhile, until the Wrappfiles `EMIT` it instead.
struct ModuleSteps {
    let bus: EventBus<AppEvent>

    /// Whether this carries `step` out.
    nonisolated static func handles(_ step: PlannedStep) -> Bool {
        switch (step.module, step.instruction) {
        case ("wine", "DRIVES"), ("wine", "REGISTRY"), ("wine", "WINETRICKS"), ("wine", "MOUNT"): true
        case ("nancy-drew", "CONFIGURE-INI"): true
        case (nil, "EDIT"): step.has("ini")
        default: false
        }
    }

    /// The executors the shipped modules have.
    nonisolated static func executors(helpers: URL? = nil, modules: Modules) -> [String: any ModuleExecutor] {
        // The shipped modules' executors, compiled in, and each added module's
        // program (docs/module-programs.md).
        let shipped: [String: any ModuleExecutor] = ["wine": WineExecutor(helpers: helpers, buildTools: wineBuildTools),
                                                     "nancy-drew": NancyDrewExecutor(), "scummvm": ScummVMExecutor(),
                                                     "basilisk": BasiliskExecutor(helpers: helpers, buildTools: {
                                                         engineBuildTools("basilisk", for: $0)
                                                     })]
        return shipped.merging(AddedModules.executors(modules.added)) { mine, _ in mine }
    }

    /// The shipped modules and those someone added, loaded once for a
    /// build's configuration: reading every module's data takes most of a
    /// second, so it's read off the main thread (`Blocking.run`), and only
    /// once.
    nonisolated struct Modules: Sendable {
        /// The shipped modules' folder.
        var root: URL?
        /// The shipped modules and the added ones that load.
        var loaded: [ModuleFolder] = []
        /// The added modules that load.
        var added: [ModuleFolder] = []

        static func load() -> Modules {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("Modules") else { return Modules() }
            var modules = Modules(root: root)
            guard let loader = try? ModuleLoader(root: root, added: AddedModules.folder()),
                  let loaded = try? loader.loadAll().get() else { return modules }
            modules.loaded = loaded
            if let shipped = try? ModuleLoader(root: root).loadAll().get() { modules.added = loader.addedModules(besides: shipped) }
            return modules
        }

        /// What each module declares, by id (`build:`).
        var declarations: [String: ModuleDeclarations] {
            Dictionary(loaded.map { ($0.manifest.id, $0.declarations) }, uniquingKeysWith: { first, _ in first })
        }

        /// The path types the modules declare (`build: path-types:`).
        var pathTypes: PathTypeRegistry { PathTypeRegistry(modules: loaded) }

        /// The modules' folders, by id, for what an executor reads of its
        /// own module's.
        var folders: [String: URL] {
            guard let root, let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
            var folders = Dictionary(uniqueKeysWithValues: ids.map { ($0, root.appendingPathComponent($0)) })
            for module in added where folders[module.manifest.id] == nil { folders[module.manifest.id] = module.folder }
            return folders
        }
    }

    /// The `build-tools` of the Wine engine the tree has, in the engine store.
    nonisolated static func wineBuildTools(for tree: URL) -> URL? { engineBuildTools("wine", for: tree) }

    /// The `build-tools` of the engine of `module` the tree has, in the engine store.
    nonisolated static func engineBuildTools(_ module: String, for tree: URL) -> URL? {
        guard let engine = EngineInstall.installed(in: tree.appendingPathComponent("Contents")).first(where: { $0.module == module })
        else { return nil }
        let tools = EngineStore.standardRoot().appendingPathComponent("\(engine.hash)/\(EngineTree.buildTools)")
        return FileManager.default.fileExists(atPath: tools.path) ? tools : nil
    }

    func run(_ step: PlannedStep, wrappPath: URL) async throws {
        let bus = bus
        let emitter = OrderedEmitter { event in
            if case .stepProgress(let progress) = event {
                await bus.publishWrappBuild(.stepProgress(progress.map { StepProgress(fraction: $0.fraction, text: $0.text ?? "") }))
            }
        }
        let plan = BuildPlan(edition: "", stages: [])
        let modules = await Blocking.run { Modules.load() }
        let configuration = RunnerConfiguration(executors: Self.executors(modules: modules), emitter: emitter,
                                                fetch: { _, _, _ in throw StepFailure.recipe("\(step.origin): this step fetches nothing") },
                                                pathTypes: modules.pathTypes, places: .shipped,
                                                moduleFolders: modules.folders)
        do {
            try await PlanRunner(plan: plan, configuration: configuration).runStep(step, stage: "", index: 0, in: wrappPath)
        } catch let error as StepFailure {
            await emitter.finish()
            throw WrappBuildError(stepFailure: error)
        } catch {
            await emitter.finish()
            throw error
        }
        await emitter.finish()
    }
}
