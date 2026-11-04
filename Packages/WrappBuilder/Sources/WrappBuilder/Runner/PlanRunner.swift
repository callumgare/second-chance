//
//  PlanRunner.swift
//  WrappBuilder
//
//  Carries out a plan: its stages in order, each step through whoever
//  carries out its instruction.

import Foundation
import Logging
import WrappModules

/// What a run of a plan is given by its caller: who carries out each
/// module's instructions, where the inputs come from, where events go, who
/// answers questions and fetches downloads.
public nonisolated struct RunnerConfiguration: Sendable {
    /// Each module's executor, by its id.
    public var executors: [String: any ModuleExecutor]
    public var inputs: any InputProvider
    public var emitter: any EventEmitter
    /// Answers a step's question: through the caller's windows, or what a
    /// headless build was given.
    public var ask: @Sendable (StepQuestion) async throws -> StepAnswer
    /// A download by URL and sha256, with its bytes so far and total.
    public var fetch: @Sendable (URL, String, @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
    /// Files the modules' Swift provides rather than their folders
    /// (`module:installer:/autoit`), by full form.
    public var providedFile: @Sendable (String) -> URL?
    /// Makes a stage itself, in its tree, when the caller has a better way
    /// than its steps (the wine prefix from its layer, until the runner keeps
    /// layers); true when it did. Also a module stage whose steps nothing
    /// here carries out.
    public var moduleStage: @Sendable (PlannedStage, URL) async throws -> Bool
    /// An engine, by module and version, from the engine store: what an
    /// `ENGINE` step installs.
    public var engine: @Sendable (String, String) async throws -> EngineStore.Engine
    public var pathTypes: PathTypeRegistry
    /// Each module's folder, by id, for what its executor reads of its own.
    public var moduleFolders: [String: URL]

    public init(executors: [String: any ModuleExecutor] = [:], inputs: any InputProvider = GivenInputs([:]),
                emitter: any EventEmitter,
                ask: @escaping @Sendable (StepQuestion) async throws -> StepAnswer = { _ in .no },
                fetch: @escaping @Sendable (URL, String, @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL,
                providedFile: @escaping @Sendable (String) -> URL? = { _ in nil },
                moduleStage: @escaping @Sendable (PlannedStage, URL) async throws -> Bool = { _, _ in false },
                engine: @escaping @Sendable (String, String) async throws -> EngineStore.Engine = { module, _ in
                    throw StepFailure.recipe("this build has no engine store to install \(module) from")
                },
                pathTypes: PathTypeRegistry = .shipped, moduleFolders: [String: URL] = [:]) {
        self.moduleFolders = moduleFolders
        self.executors = executors
        self.inputs = inputs
        self.emitter = emitter
        self.ask = ask
        self.fetch = fetch
        self.providedFile = providedFile
        self.moduleStage = moduleStage
        self.engine = engine
        self.pathTypes = pathTypes
    }
}

/// Carries out a `BuildPlan` (docs/wrapp-build.md#the-runner): any plan
/// that checks can be built by any source. A step whose instruction no
/// executor carries out fails, naming it. Off the main actor whoever
/// starts it.
public nonisolated struct PlanRunner: Sendable {
    public let plan: BuildPlan
    public let configuration: RunnerConfiguration
    private let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.PlanRunner")

    public init(plan: BuildPlan, configuration: RunnerConfiguration) {
        self.plan = plan
        self.configuration = configuration
    }

    /// Every stage of the plan, in order, in `tree`: the stages share one
    /// tree until each has its own. Each executor's `finish` is called at
    /// the end, on success, failure or cancel.
    @concurrent
    public func run(in tree: URL) async throws {
        do {
            for stage in plan.stages {
                try await run(stage, in: tree, trees: [:])
            }
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    /// Every stage of the plan, each in its own tree in `folder` (a tree
    /// shared down a linear chain, cloned where stages branch: `StageTrees`):
    /// the target's tree, which is the wrapp. The other stages' trees stay in
    /// the folder, for whoever owns it to remove.
    @concurrent
    public func build(in folder: URL) async throws -> URL {
        let trees = StageTrees(plan: plan, in: folder)
        guard let target = trees.target else { throw StepFailure.recipe("the plan has no stages") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (stage, start) in zip(plan.stages, trees.starts) {
                try Task.checkCancellation()
                try StageTrees.prepare(start)
                guard let tree = trees.trees[stage.name] else { continue }
                try await run(stage, in: tree, trees: trees.trees)
            }
        } catch {
            await finish()
            throw error
        }
        await finish()
        return target
    }

    func run(_ stage: PlannedStage, in tree: URL, trees: [String: URL]) async throws {
        try Task.checkCancellation()
        if try await configuration.moduleStage(stage, tree) {
            logger.notice("[Runner] The \(stage.name) stage was made for the build")
            return
        }
        if stage.isModuleStage, !runsItself(stage) {
            throw StepFailure.recipe("nothing carries out the \(stage.name) stage's steps in this build")
        }
        for (index, step) in stage.steps.enumerated() {
            try Task.checkCancellation()
            emit(stage.emits(before: index))
            try await run(step, at: StepRef(stage: stage.name, index: index, step: step), in: tree, trees: trees)
        }
        emit(stage.emits(before: stage.steps.count))
    }

    /// Whether every step of a module's stage has someone to carry it out.
    func runsItself(_ stage: PlannedStage) -> Bool {
        stage.steps.allSatisfy { step in step.module.map { configuration.executors[$0] != nil } ?? true }
    }

    /// One step, in `tree`: for a builder that carries out a plan's steps
    /// itself and hands this the ones an executor carries out, until every
    /// source builds through `run(in:)`.
    public func runStep(_ step: PlannedStep, stage: String, index: Int, in tree: URL) async throws {
        try await run(step, at: StepRef(stage: stage, index: index, step: step), in: tree, trees: [:])
    }

    func run(_ step: PlannedStep, at ref: StepRef, in tree: URL, trees: [String: URL]) async throws {
        let context = LocalStepContext(tree: tree, step: step, plan: plan, configuration: configuration, trees: trees)
        configuration.emitter.emit(.stepStarted(ref))
        configuration.emitter.emit(.stepProgress(nil))
        logger.notice("Step: \(step) (\(step.origin))")
        let started = ContinuousClock.now
        do {
            if let module = step.module {
                guard let executor = configuration.executors[module] else {
                    throw StepFailure.recipe("\(step.origin): nothing carries out \(step.keyword) in this build")
                }
                try await executor.run(step, in: context)
            } else {
                try await CoreInstructions.run(step, in: context)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // A step that may be carried on without asks whether to.
            guard step.option("on-failure") == "ask" else { throw error }
            let message = String(describing: error)
            logger.error("[Runner] \(ref.name) failed: \(message)")
            guard try await configuration.ask(.confirmStepFailure(name: ref.name, message: message)) == .yes else { throw error }
            logger.warning("[Runner] Carrying on without \(ref.name)")
            configuration.emitter.emit(.stepSkipped(ref, message: message))
            return
        }
        logger.debug("[Runner] \(ref.name) took \(ContinuousClock.now - started)")
        configuration.emitter.emit(.stepDone(ref))
    }

    /// A stage's `EMIT`s, as the build reaches them.
    func emit(_ emits: [PlannedEmit]) {
        for emitted in emits { configuration.emitter.emit(.emitted(emitted.text)) }
    }

    func finish() async {
        for executor in configuration.executors.values { await executor.finish() }
    }
}
