//
//  Layering.swift
//  WrappBuilder
//
//  Which of a build's layers are restored, which kept, and the events that
//  go with them.

import Foundation
import Logging
import ProcessKit
import Synchronization

/// A build's layers (decisions 12 to 18 of the builders plan): each step's
/// key, the deepest kept layer each stage can start from, which stages need
/// building at all, and keeping a layer after a step where one is suggested.
nonisolated final class Layering: Sendable {
    let plan: BuildPlan
    let configuration: RunnerConfiguration
    let keys: StepKeys
    /// Each stage's deepest step with a kept layer, by name.
    let restorable: [String: Int]
    /// Set once a step is skipped: what the build makes from then on isn't
    /// what its keys say, so nothing more is kept or restored.
    private let tainted = Mutex(false)
    private let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Layers")

    init(plan: BuildPlan, configuration: RunnerConfiguration, trees: [String: URL]) async throws {
        self.plan = plan
        self.configuration = configuration
        // Nothing carried over from an input's tree (an update's old app) is
        // cached: it's one person's, and no key could say what it holds.
        let fromInput = plan.stages.contains { if case .input = $0.from { true } else { false } }
        guard let store = configuration.layers, configuration.layerPolicy != .off, !fromInput else {
            keys = StepKeys()
            restorable = [:]
            return
        }
        let keys = try await StepKeys.make(for: plan, configuration: configuration, trees: trees)
        var restorable: [String: Int] = [:]
        for stage in plan.stages where Self.allows(stage, configuration.layerPolicy) {
            let stageKeys = keys.keys[stage.name] ?? []
            if let deepest = stageKeys.indices.reversed().first(where: { store.lookup(stageKeys[$0]) != nil }) {
                restorable[stage.name] = deepest
            }
        }
        self.keys = keys
        self.restorable = restorable
    }

    static func allows(_ stage: PlannedStage, _ policy: LayerPolicy) -> Bool {
        switch policy {
        case .all: true
        case .modules: stage.isModuleStage
        case .off: false
        }
    }

    func taint() { tainted.withLock { $0 = true } }
    var isTainted: Bool { tainted.withLock { $0 } }

    /// The stages still to build, walking back from the target: a stage is
    /// needed if a needed stage starts from it with nothing restored, or a
    /// step still to run in one copies from it.
    /// Why each stage the policy caches has nothing to restore, for the
    /// log: which of its deepest layer's inputs differ from the layer last
    /// kept in that place (`LayerStore.explain`).
    func explainMisses() {
        guard let store = configuration.layers else { return }
        for stage in plan.stages where restorable[stage.name] == nil && Self.allows(stage, configuration.layerPolicy) {
            guard let index = stage.steps.indices.reversed().first(where: { reason(stage, $0) != nil }),
                  let key = keys.keys[stage.name]?[index], let why = store.explain(key) else { continue }
            logger.notice("[Layer] Nothing kept to restore for \(stage.name.isEmpty ? "the target" : stage.name): \(why)")
        }
    }

    func neededStages() -> Set<String> {
        guard let target = plan.stages.last else { return [] }
        var needed: Set<String> = [target.name]
        for stage in plan.stages.reversed() where needed.contains(stage.name) {
            let restored = restorable[stage.name]
            if restored == nil, let parent = Self.parent(of: stage) { needed.insert(parent) }
            for step in stage.steps.dropFirst((restored ?? -1) + 1) where step.module == nil && step.instruction == "COPY" {
                if let from = step.option("from"), plan.stages.contains(where: { $0.name == from }) { needed.insert(from) }
            }
        }
        return needed
    }

    static func parent(of stage: PlannedStage) -> String? {
        switch stage.from {
        case .scratch, .input: nil
        case .stage(let name): name
        case .module(let id, _, let moduleStage): "\(id.lowercased())/\(moduleStage)"
        }
    }

    /// Put the deepest kept layer of `stage` in its tree, and replay its
    /// lasting events, each tagged `replayed`: the index of its step, or nil
    /// when there's none to restore.
    func restore(_ stage: PlannedStage, into tree: URL, start: StageTrees.Start, emitter: any EventEmitter,
                 log: inout [BuildEvent]) async throws -> Int? {
        guard let index = restorable[stage.name], let store = configuration.layers,
              let key = keys.keys[stage.name]?[index], let layer = store.lookup(key) else { return nil }
        let restored = try await Blocking.run {
            if FileManager.default.fileExists(atPath: tree.path) { try FileManager.default.removeItem(at: tree) }
            return try store.restore(layer, to: tree)
        }
        let copied = restored == .copied ? ", copied as the store is on another volume" : ""
        logger.notice("[Layer] Restored \(stage.name) through step \(index + 1) (\(key.hash.prefix(12))…)\(copied)")
        let events = (layer.events.flatMap { try? JSONDecoder().decode([BuildEvent].self, from: $0) }) ?? []
        for event in events { emitter.emit(.replayed(event)) }
        log = events
        return index
    }

    /// Keep a layer after step `index` of `stage` if one is suggested there,
    /// the policy allows it, and the store hasn't it already: the tree's
    /// executors checkpointed first (Wine's session ended, so its registry
    /// is written), then the tree cloned in, with its lasting events.
    func keepIfSuggested(_ stage: PlannedStage, index: Int, tree: URL, log: [BuildEvent], executors: [any ModuleExecutor]) async throws {
        guard let store = configuration.layers, Self.allows(stage, configuration.layerPolicy), !isTainted,
              let key = keys.keys[stage.name]?[index], let why = reason(stage, index) else { return }
        guard store.lookup(key) == nil else { return }
        let started = ContinuousClock.now
        let step = stage.steps[index]
        let context = LocalStepContext(tree: tree, step: step, plan: plan, configuration: configuration)
        for executor in executors { try await executor.checkpoint(context) }
        logger.notice("[Layer] checkpoint took \(ContinuousClock.now - started)")
        let events = try JSONEncoder().encode(log)
        do {
            _ = try await store.layer(for: key) { content in
                try await Blocking.run { try FileCopy.clone(tree, to: content) }
                return events
            }
            logger.notice("[Layer] Kept \(stage.name) after step \(index + 1), \(step.keyword) (\(why)): \(key.hash.prefix(12))…")
        } catch {
            // A layer only saves the next build time: this one carries on.
            logger.warning("[Layer] Couldn't keep a layer after \(stage.name) step \(index + 1): \(error.localizedDescription)")
        }
    }

    /// Why a layer is worth keeping after step `index`, or nil.
    func reason(_ stage: PlannedStage, _ index: Int) -> String? {
        let step = stage.steps[index]
        if configuration.layerEveryStep { return "every step" }
        if step.endsLayerHint { return "LAYER-HINT" }
        let isLast = index == stage.steps.count - 1
        if isLast, stage.isModuleStage || plan.stages.contains(where: { Self.parent(of: $0) == stage.name })
            || plan.stages.flatMap(\.steps).contains(where: { $0.module == nil && $0.instruction == "COPY" && $0.option("from") == stage.name }) {
            return "stage parent"
        }
        if step.inLayerHint { return nil }
        if configuration.suggestsLayer(step) { return "module" }
        if step.module == nil, ["ADD", "RUN"].contains(step.instruction) { return "core" }
        return nil
    }
}

/// Passes events on, keeping the lasting ones for a layer.
nonisolated final class LogRecorder: EventEmitter {
    let inner: any EventEmitter
    private let lasting = Mutex<[BuildEvent]>([])

    init(inner: any EventEmitter) { self.inner = inner }

    func emit(_ event: BuildEvent) {
        inner.emit(event)
        if event.lasting { lasting.withLock { $0.append(event) } }
    }

    /// What's been kept since the last take.
    func take() -> [BuildEvent] { lasting.withLock { events in defer { events = [] }; return events } }
}
