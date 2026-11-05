//
//  main.swift
//  wrapp-module-fixture
//
//  A module's program, as someone adding a module would write one: an
//  executor, served over the module protocol. `EXAMPLE.COPY-TREE <input>
//  --into=<place>` copies the input into the tree, saying so as it goes.

import Foundation
import Logging
import WrappModuleKit

struct CopyTree: ModuleExecutor {
    static let handles = ["COPY-TREE"]

    func keyInputs(for step: PlannedStep, in context: any StepContext) async throws -> KeyInputs {
        KeyInputs([KeyInput("copies", step.arguments.first ?? "")])
    }

    func run(_ step: PlannedStep, in context: any StepContext) async throws {
        guard let name = step.arguments.first.flatMap(PlannedStep.input(in:)), let into = step.option("into") else {
            throw StepFailure.recipe("\(step.origin): COPY-TREE copies an input --into a place")
        }
        let source = try await context.input(name)
        context.substep("Copying the files")
        context.log.notice("copying \(source.lastPathComponent)")
        let target = context.tree.appendingPathComponent("Contents").appendingPathComponent(into.hasPrefix("/") ? String(into.dropFirst()) : into)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        context.emit("example.copied")
    }
}

try await ModuleProgram.serve(CopyTree())
