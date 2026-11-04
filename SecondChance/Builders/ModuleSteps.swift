//
//  ModuleSteps.swift
//  SecondChance
//
//  The steps a builder that carries out its plan itself hands to the
//  modules' executors: until every source builds through the runner.

import Foundation
import Logging
import NancyDrewExecutor
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
    nonisolated static func executors(helpers: URL? = nil) -> [String: any ModuleExecutor] {
        ["wine": WineExecutor(helpers: helpers, buildTools: wineBuildTools), "nancy-drew": NancyDrewExecutor()]
    }

    /// The `build-tools` of the Wine engine the tree has, in the engine store.
    nonisolated static func wineBuildTools(for tree: URL) -> URL? {
        guard let wine = EngineInstall.installed(in: tree.appendingPathComponent("Contents")).first(where: { $0.module == "wine" })
        else { return nil }
        let tools = EngineStore.standardRoot().appendingPathComponent("\(wine.hash)/\(EngineTree.buildTools)")
        return FileManager.default.fileExists(atPath: tools.path) ? tools : nil
    }

    /// What each shipped module declares, by id (`build:`).
    nonisolated static func moduleDeclarations() -> [String: ModuleDeclarations] {
        guard let modules = Bundle.main.resourceURL?.appendingPathComponent("Modules"),
              let loaded = try? ModuleLoader(root: modules).loadAll().get() else { return [:] }
        return Dictionary(uniqueKeysWithValues: loaded.map { ($0.manifest.id, $0.declarations) })
    }

    /// The shipped modules' folders, by id, for what an executor reads of
    /// its own module's.
    nonisolated static func moduleFolders() -> [String: URL] {
        guard let modules = Bundle.main.resourceURL?.appendingPathComponent("Modules"),
              let ids = try? FileManager.default.contentsOfDirectory(atPath: modules.path) else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, modules.appendingPathComponent($0)) })
    }

    func run(_ step: PlannedStep, wrappPath: URL) async throws {
        let bus = bus
        let emitter = OrderedEmitter { event in
            if case .stepProgress(let progress) = event {
                await bus.publishWrappBuild(.stepProgress(progress.map { StepProgress(fraction: $0.fraction, text: $0.text ?? "") }))
            }
        }
        let plan = BuildPlan(edition: "", stages: [])
        let configuration = RunnerConfiguration(executors: Self.executors(), emitter: emitter,
                                                fetch: { _, _, _ in throw StepFailure.recipe("\(step.origin): this step fetches nothing") },
                                                moduleFolders: Self.moduleFolders())
        do {
            try await PlanRunner(plan: plan, configuration: configuration).runStep(step, stage: "", index: 0, in: wrappPath)
        } catch let error as StepFailure {
            await emitter.finish()
            throw WrappBuildError.buildRecipeProblem(error.description)
        } catch {
            await emitter.finish()
            throw error
        }
        await emitter.finish()
    }
}
