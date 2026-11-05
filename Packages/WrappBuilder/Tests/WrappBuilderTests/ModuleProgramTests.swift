import Foundation
import Testing
@testable import WrappBuilder
import WrappFormat
import WrappModules

/// A module's program, out of process: the runner carries its step out
/// through `ExternalExecutor` and the module protocol, as it would a
/// compiled-in executor's.
struct ModuleProgramTests {
    /// The fixture program SwiftPM built beside the tests.
    static var fixture: URL {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.lastPathComponent != "WrappBuilder" { folder.deleteLastPathComponent() }
        return folder.appendingPathComponent(".build/debug/wrapp-module-fixture")
    }

    @Test("A module's program carries its step out, asking the build for its input and emitting through it")
    func outOfProcess() async throws {
        let program = Self.fixture
        try #require(FileManager.default.isExecutableFile(atPath: program.path), "No fixture program at \(program.path)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("module-program-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: input.appendingPathComponent("game.dat"))
        let tree = root.appendingPathComponent("tree.app")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Contents"), withIntermediateDirectories: true)

        let step = PlannedStep(instruction: "COPY-TREE", module: "example/copy-tree", options: ["into": ["/SharedSupport/game"]],
                               arguments: [PlannedStep.inputToken("game")], name: nil, origin: "Wrappfile:3")
        let plan = BuildPlan(edition: "x", stages: [PlannedStage(name: "only", from: .scratch, modules: ["example/copy-tree"], steps: [step])])
        let executor = ExternalExecutor(module: "example/copy-tree", release: 1, program: program)
        let recorder = PlanRunnerTests.Recorder()
        let configuration = RunnerConfiguration(executors: ["example/copy-tree": executor], inputs: GivenInputs(["game": input]),
                                                emitter: recorder, fetch: { _, _, _ in throw StepFailure.failed("no downloads") },
                                                pathTypes: PathTypeRegistry([]))
        try await PlanRunner(plan: plan, configuration: configuration).run(in: tree)

        #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("Contents/SharedSupport/game/game.dat").path))
        #expect(recorder.all.contains(.substep("Copying the files")))
        #expect(recorder.all.contains(.emitted("example.copied")))
        // Its key has the program's hash, and what it adds.
        let inputs = try await executor.keyInputs(for: step, in: LocalStepContext(tree: tree, step: step, plan: plan, configuration: configuration))
        #expect(inputs.inputs.map(\.name) == ["program", "copies"])
        await executor.finish()
    }

    @Test("A module's program is sandboxed: it writes to the temporary folder, and nowhere else",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "macOS has sandbox-exec"))
    func sandbox() throws {
        func touches(_ file: URL) throws -> Bool {
            let (sandbox, arguments) = try #require(ExternalExecutor.sandboxed(URL(fileURLWithPath: "/usr/bin/touch")))
            let process = Process()
            process.executableURL = sandbox
            process.arguments = arguments + [file.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let inside = FileManager.default.temporaryDirectory.appendingPathComponent("module-sandbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inside) }
        #expect(try touches(inside))
        let outside = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("module-sandbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(try !touches(outside))
        #expect(ExternalExecutor.sandboxed(URL(fileURLWithPath: "/usr/bin/true"), environment: ["SECOND_CHANCE_MODULE_SANDBOX": "0"]) == nil)
    }

    @Test("A recipe problem in a program's step is the build's recipe problem")
    func recipeProblem() async throws {
        let program = Self.fixture
        try #require(FileManager.default.isExecutableFile(atPath: program.path))
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("module-program-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: tree) }
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let step = PlannedStep(instruction: "COPY-TREE", module: "example/copy-tree", options: [:], arguments: [], name: nil, origin: "Wrappfile:3")
        let plan = BuildPlan(edition: "x", stages: [PlannedStage(name: "only", from: .scratch, modules: ["example/copy-tree"], steps: [step])])
        let executor = ExternalExecutor(module: "example/copy-tree", release: 1, program: program)
        let configuration = RunnerConfiguration(executors: ["example/copy-tree": executor], emitter: PlanRunnerTests.Recorder(),
                                                fetch: { _, _, _ in throw StepFailure.failed("no downloads") }, pathTypes: PathTypeRegistry([]))
        await #expect(throws: StepFailure.recipe("Wrappfile:3: COPY-TREE copies an input --into a place")) {
            try await PlanRunner(plan: plan, configuration: configuration).run(in: tree)
        }
    }
}
