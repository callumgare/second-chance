//
//  LocalStepContext.swift
//  WrappBuilder
//
//  The runner's own StepContext, for an executor compiled in.

import Foundation
import Logging
import WrappFormat
import WrappModules

/// What a step is given when it runs in the build's own process: the
/// runner's tree, plan, inputs, emitter, questions and downloads.
nonisolated struct LocalStepContext: StepContext {
    let tree: URL
    let step: PlannedStep
    let plan: BuildPlan
    let configuration: RunnerConfiguration
    /// Each stage's tree, by name; empty while every stage shares one.
    var trees: [String: URL] = [:]
    let log = Logger(label: "au.gare.callum.second-chance.SecondChance.Step")

    var emitter: any EventEmitter { configuration.emitter }

    /// Another stage's tree; while every stage shares one, this one.
    func tree(ofStage name: String) -> URL? {
        if !trees.isEmpty { return trees[name] }
        return plan.stages.contains { $0.name == name } ? tree : nil
    }

    func file(_ fullForm: String) -> URL? { plan.file(fullForm) ?? configuration.providedFile(fullForm) }

    func input(_ name: String) async throws -> URL { try await configuration.inputs.input(name) }

    func moduleFile(_ module: String, _ path: String) -> URL? {
        configuration.moduleFolders[module.lowercased()].map { $0.appendingPathComponent(path) }
    }

    func ask(_ question: StepQuestion) async throws -> StepAnswer { try await configuration.ask(question) }

    /// The program through its path type's module, with `mounts` put in
    /// place first and taken away after, whatever happens.
    func runProgram(_ program: ProgramRun, mounts: [String]) async throws -> Int32 {
        guard let (type, _) = configuration.pathTypes.split(program.program) else {
            throw StepFailure.recipe("\(program.step.origin): \(program.program) runs in no engine, and a build runs programs only in one")
        }
        guard let executor = configuration.executors[type.module.rawValue] else {
            throw StepFailure.recipe("\(program.step.origin): nothing runs \(type.name): programs in this build")
        }
        let placed = try await Mounts.place(mounts, for: program.step, in: self)
        do {
            let code = try await executor.runProgram(program, in: self)
            await Mounts.remove(placed, log: log)
            return code
        } catch {
            await Mounts.remove(placed, log: log)
            throw error
        }
    }

    func fetch(url: URL, sha256: String) async throws -> URL {
        let emitter = configuration.emitter
        return try await configuration.fetch(url, sha256) { done, total in
            let text = total.map { "\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of "
                + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            emitter.emit(.stepProgress(.init(fraction: total.map { Double(done) / Double(max($0, 1)) }, text: text)))
        }
    }

    /// Where a location in full form is in the step's tree.
    func location(_ fullForm: String) throws -> URL {
        guard let url = WrappLayout(app: tree).location(fullForm) else {
            throw StepFailure.recipe("\(step.origin): \(fullForm) has no place in the app")
        }
        return url
    }
}
