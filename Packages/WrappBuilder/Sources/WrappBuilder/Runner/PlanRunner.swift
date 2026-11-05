//
//  PlanRunner.swift
//  WrappBuilder
//
//  Carries out a plan: its stages in order, each step through whoever
//  carries out its instruction.

import Foundation
import Logging
import WrappFormat
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
    /// Where layers are kept, and which (decisions 12 to 15 of the builders
    /// plan); none without a store.
    public var layers: LayerStore?
    public var layerPolicy: LayerPolicy = .off
    /// `--debug layer-every-step`: a layer after every step, for finding
    /// which step of a group broke.
    public var layerEveryStep = false
    /// Whether a step's module says a layer after it is worth keeping
    /// (`layer: suggested`).
    public var suggestsLayer: @Sendable (PlannedStep) -> Bool = { _ in false }
    /// The data tables a step's executor reads in Swift (`reads-data`), as
    /// files of its module's folder (`ini.yaml`).
    public var readsData: @Sendable (PlannedStep) -> [String] = { _ in [] }
    /// The revision of the Swift that carries a step out, in its key.
    public var revision: @Sendable (PlannedStep) -> Int = { _ in 1 }
    /// Where the build's stores are, and whose; nil for a build that keeps
    /// none, in which a store mount fails.
    public var stores: StoreSettings?
    /// The build's, by which it holds a store's lock: a step of the same
    /// build shares it, another build waits.
    public var buildToken = UUID()

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
    /// The build's `EMIT --on` listeners.
    let listeners = Listeners()
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
    ///
    /// With a layer store, every step is keyed first (`StepKeys`), and each
    /// stage restores its deepest kept layer and runs from the step after
    /// it; a stage nothing still to run reads isn't built at all. A layer is
    /// kept after a step where one is suggested and the policy allows.
    @concurrent
    public func build(in folder: URL) async throws -> URL {
        let trees = StageTrees(plan: plan, in: folder)
        guard let target = trees.target else { throw StepFailure.recipe("the plan has no stages") }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let layering = try await Layering(plan: plan, configuration: configuration, trees: trees.trees)
            layering.explainMisses()
            let needed = layering.neededStages()
            var logs: [URL: [BuildEvent]] = [:]
            for (stage, start) in zip(plan.stages, trees.starts) {
                try Task.checkCancellation()
                guard needed.contains(stage.name) else {
                    logger.notice("[Layer] Not building \(stage.name): nothing still to run reads it")
                    continue
                }
                guard let tree = trees.trees[stage.name] else { continue }
                // The events kept with a layer are the lasting ones of every
                // step the tree holds, its parents' included.
                switch start {
                case .clone(let parent, _): logs[tree] = logs[parent] ?? []
                case .empty, .input: logs[tree] = []
                case .parentsTree: break
                }
                let restoredThrough = try await layering.restore(stage, into: tree, start: start, emitter: configuration.emitter,
                                                                 log: &logs[tree, default: []])
                if restoredThrough == nil { try await StageTrees.prepare(start, inputs: configuration.inputs) }
                try await run(stage, in: tree, trees: trees.trees, from: (restoredThrough ?? -1) + 1, layering: layering,
                              log: &logs[tree, default: []])
            }
        } catch {
            await finish()
            throw error
        }
        await finish()
        return target
    }

    func run(_ stage: PlannedStage, in tree: URL, trees: [String: URL]) async throws {
        var log: [BuildEvent] = []
        try await run(stage, in: tree, trees: trees, from: 0, layering: nil, log: &log)
    }

    func run(_ stage: PlannedStage, in tree: URL, trees: [String: URL], from first: Int, layering: Layering?,
             log: inout [BuildEvent]) async throws {
        try Task.checkCancellation()
        if first == 0, try await configuration.moduleStage(stage, tree) {
            logger.notice("[Runner] The \(stage.name) stage was made for the build")
            return
        }
        if stage.isModuleStage, !runsItself(stage) {
            throw StepFailure.recipe("nothing carries out the \(stage.name) stage's steps in this build")
        }
        let recorder = LogRecorder(inner: configuration.emitter)
        for (index, step) in stage.steps.enumerated() where index >= first {
            try Task.checkCancellation()
            try emit(stage.emits(before: index), to: recorder)
            let skipped = try await run(step, at: StepRef(stage: stage.name, index: index, step: step), in: tree, trees: trees,
                                        emitter: recorder)
            if skipped { layering?.taint() }
            log += recorder.take()
            try await layering?.keepIfSuggested(stage, index: index, tree: tree, log: log, executors: Array(configuration.executors.values))
        }
        try emit(stage.emits(before: stage.steps.count), to: recorder)
        log += recorder.take()
    }

    /// Whether every step of a module's stage has someone to carry it out.
    func runsItself(_ stage: PlannedStage) -> Bool {
        stage.steps.allSatisfy { step in step.module.map { configuration.executors[$0] != nil } ?? true }
    }

    /// One step, in `tree`: for a builder that carries out a plan's steps
    /// itself and hands this the ones an executor carries out, until every
    /// source builds through `run(in:)`.
    public func runStep(_ step: PlannedStep, stage: String, index: Int, in tree: URL) async throws {
        _ = try await run(step, at: StepRef(stage: stage, index: index, step: step), in: tree, trees: [:], emitter: configuration.emitter)
    }

    /// Whether the step was skipped (`--on-failure=ask`, and carried on without).
    @discardableResult
    func run(_ step: PlannedStep, at ref: StepRef, in tree: URL, trees: [String: URL], emitter: any EventEmitter) async throws -> Bool {
        var configuration = configuration
        configuration.emitter = emitter
        var context = LocalStepContext(tree: tree, step: step, plan: plan, configuration: configuration, trees: trees)
        // Its signals and the build's listeners, watched while it runs.
        let executors = configuration.executors
        let watchContext = context
        let signals = StepSignals(step: step, plan: plan, listeners: listeners.all, emitter: emitter,
                                  resolve: { WrappLayout(app: tree).location($0) },
                                  moduleWatch: { id, name, value in executors[id]?.watch(name, value: value, in: watchContext) })
        context.signals = signals
        signals.start()
        defer { signals.finish() }
        emitter.emit(.stepStarted(ref))
        emitter.emit(.stepProgress(nil))
        logger.notice("Step: \(step) (\(step.origin))")
        let started = ContinuousClock.now
        do {
            // Its mounts, put in place for it and taken away after, whoever
            // carries it out; and its stores' locks let go.
            defer { context.holds.releaseAll() }
            let mounts = (step.options["mount"] ?? []).filter { ["bind", "fetch", "store"].contains(PlannedStep.fields(ofMount: $0)["type"]) }
            let placed = try await Mounts.place(mounts, for: step, in: context)
            do {
                if let module = step.module {
                    guard let executor = configuration.executors[module] else {
                        throw StepFailure.recipe("\(step.origin): nothing carries out \(step.keyword) in this build")
                    }
                    try await executor.run(step, in: context)
                } else {
                    try await CoreInstructions.run(step, in: context)
                }
            } catch {
                await Mounts.remove(placed, log: context.log)
                throw error
            }
            await Mounts.remove(placed, log: context.log)
        } catch let error as CancellationError {
            throw error
        } catch {
            // A step that may be carried on without asks whether to.
            guard step.option("on-failure") == "ask" else { throw error }
            let message = String(describing: error)
            logger.error("[Runner] \(ref.name) failed: \(message)")
            guard try await configuration.ask(.confirmStepFailure(name: ref.name, message: message)) == .yes else { throw error }
            logger.warning("[Runner] Carrying on without \(ref.name)")
            emitter.emit(.stepSkipped(ref, message: message))
            return true
        }
        logger.notice("[Runner] \(ref.name) took \(ContinuousClock.now - started)")
        emitter.emit(.stepDone(ref))
        return false
    }

    /// A stage's `EMIT`s, as the build reaches them: a string passed on, or
    /// a listener started or stopped.
    func emit(_ emits: [PlannedEmit], to emitter: (any EventEmitter)? = nil) throws {
        for emitted in emits where try !listeners.reach(emitted) {
            (emitter ?? configuration.emitter).emit(.emitted(emitted.text))
        }
    }

    func finish() async {
        for executor in configuration.executors.values { await executor.finish() }
        // The build's session stores end with it.
        if let session = configuration.stores?.locations.session, FileManager.default.fileExists(atPath: session.path) {
            do {
                try FileManager.default.removeItem(at: session)
            } catch {
                logger.warning("[Runner] Couldn't remove the build's session stores: \(error.localizedDescription)")
            }
        }
    }
}
