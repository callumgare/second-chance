//
//  StepKeys.swift
//  WrappBuilder
//
//  Every step's key, and where layers are kept and restored.

import Foundation

/// Which layers a build keeps and restores (`SECOND_CHANCE_LAYER_CACHE`):
/// every one; only module stages' (the wine prefix, Steam's client), which
/// is what a test builds with, so every game is still installed for real;
/// or none.
public nonisolated enum LayerPolicy: String, Sendable {
    case all
    case modules
    case off

    /// `prefix` is what the policy that kept only the wine prefix was called.
    public init?(named name: String) {
        if name == "prefix" { self = .modules } else { self.init(rawValue: name) }
    }
}

nonisolated extension LayerKey {
    /// Raised whenever what goes into a step's key, or how, changes: no key
    /// made before could then match one made after.
    public static let formatVersion = 1
}

/// Each step's key (decision 14 of the builders plan): its parent's (the
/// step before it, or for a stage's first, its parent stage's last), and its
/// own inputs: its text as planned, the files and data tables it reads, its
/// executor's revision, its inputs' fingerprints, the key of a stage it
/// copies from, and what its executor's `keyInputs` add. So a change
/// anywhere changes every key after it, and none before.
nonisolated struct StepKeys: Sendable {
    /// By stage name, a key for each step.
    var keys: [String: [LayerKey]] = [:]

    /// The key a stage starts from: the builder's own, for one from scratch.
    static func base() -> LayerKey {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return LayerKey(slot: "builder", inputs: [.init("format", String(LayerKey.formatVersion)), .init("arch", arch)])
    }

    /// The last key of `stage`, which a stage built from it, or copying from
    /// it, is keyed on.
    func last(of stage: String) -> LayerKey? { keys[stage]?.last }

    static func make(for plan: BuildPlan, configuration: RunnerConfiguration, trees: [String: URL]) async throws -> StepKeys {
        var made = StepKeys()
        for stage in plan.stages {
            var parent: LayerKey
            switch stage.from {
            case .scratch, .input: parent = base()
            case .stage(let name): parent = made.last(of: name) ?? base()
            case .module(let id, _, let moduleStage): parent = made.last(of: "\(id.lowercased())/\(moduleStage)") ?? base()
            }
            var keys: [LayerKey] = []
            for (index, step) in stage.steps.enumerated() {
                let context = LocalStepContext(tree: trees[stage.name] ?? URL(fileURLWithPath: "/"), step: step, plan: plan,
                                               configuration: configuration, trees: trees)
                var inputs: [LayerKey.Input] = [.init("step", step.description)]
                for file in Self.files(of: step) {
                    guard let url = context.file(file) else { continue }
                    var isFolder: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
                    inputs.append(.init(file, isFolder.boolValue ? try LayerKey.hash(folder: url) : try LayerKey.hash(file: url)))
                }
                for table in step.tables {
                    guard let url = context.file(table) else { continue }
                    inputs.append(.init(table, try LayerKey.hash(file: url)))
                }
                // The tables its executor reads in Swift (`reads-data`).
                if let module = step.module {
                    for table in configuration.readsData(step) {
                        guard let url = context.moduleFile(module, table), FileManager.default.fileExists(atPath: url.path) else { continue }
                        inputs.append(.init("module:\(module):/\(table)", try LayerKey.hash(file: url)))
                    }
                }
                inputs.append(.init("revision", String(configuration.revision(step))))
                // Only what's to hand: keys are made before anything runs,
                // and working out a disc 2 would eject disc 1 before it's
                // copied. One not to hand is keyed as such, the same each
                // build.
                for name in Self.inputs(of: step) {
                    guard let url = try await context.configuration.inputs.inputIfReady(name) else {
                        inputs.append(.init("input \(name)", "given when needed"))
                        continue
                    }
                    inputs.append(.init("input \(name)", try Self.fingerprint(url)))
                }
                // An engine by its prepared hash, as one prepared again at the
                // same version (a Rosetta fix) is another engine.
                if step.module == nil, step.instruction == "ENGINE", let named = step.arguments.first, let at = named.firstIndex(of: "@") {
                    let engine = try await configuration.engine(String(named[..<at]), String(named[named.index(after: at)...]))
                    inputs.append(.init("engine", engine.hash))
                }
                if step.module == nil, step.instruction == "COPY", let from = step.option("from"), let copied = made.last(of: from) {
                    inputs.append(.init("copied from \(from)", copied.hash))
                }
                if let module = step.module, let executor = configuration.executors[module] {
                    inputs += try await executor.keyInputs(for: step, in: context).inputs.map { LayerKey.Input($0.name, $0.value) }
                }
                let key = LayerKey(slot: "\(stage.name) \(index + 1): \(step.keyword)", parent: parent, inputs: inputs)
                keys.append(key)
                parent = key
            }
            made.keys[stage.name] = keys
        }
        return made
    }

    /// The bundle's and modules' files a step names, by full form.
    static func files(of step: PlannedStep) -> [String] {
        var words = step.arguments + step.options.values.flatMap { $0 }
        words += step.mounts.flatMap(\.values)
        return Array(Set(words.filter { $0.hasPrefix("bundle:") || $0.hasPrefix("module:") })).sorted()
    }

    /// The inputs a step reads, by name.
    static func inputs(of step: PlannedStep) -> [String] {
        var words = step.arguments + step.options.values.flatMap { $0 }
        words += step.mounts.flatMap(\.values)
        return Array(Set(words.compactMap(PlannedStep.input(in:)))).sorted()
    }

    /// What stands for an input's contents in a key without reading it all:
    /// a file's size and modification time; a folder's listing, every file's
    /// path, size and modification time (a macOS bundle is listed as any
    /// folder: its own time changes only when its top level does).
    static func fingerprint(_ url: URL) throws -> String {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return "missing" }
        if isFolder.boolValue { return try LayerKey.listing(of: url) }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "size:\(values.fileSize ?? 0),mtime:\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}
