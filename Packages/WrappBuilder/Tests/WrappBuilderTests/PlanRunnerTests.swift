import Foundation
import Synchronization
import Testing
@testable import WrappBuilder
import WrappFormat
import WrappModules

/// The runner, with fake executors: nothing runs but the core's own file
/// work, in a temporary tree.
struct PlanRunnerTests {
    /// Events, in order.
    final class Recorder: EventEmitter {
        let events = Mutex<[BuildEvent]>([])
        func emit(_ event: BuildEvent) { events.withLock { $0.append(event) } }
        var all: [BuildEvent] { events.withLock { $0 } }
    }

    /// An executor that records what it was asked to do, and fails a step
    /// told to.
    final class FakeExecutor: ModuleExecutor {
        static let handles = ["DO-IT", "FAIL"]
        let calls = Mutex<[String]>([])
        let finished = Mutex(false)
        func run(_ step: PlannedStep, in context: any StepContext) async throws {
            calls.withLock { $0.append(step.instruction) }
            if step.instruction == "FAIL" { throw StepFailure.failed("it failed") }
        }
        func runProgram(_ program: ProgramRun, in context: any StepContext) async throws -> Int32 {
            // The mount is there while the program runs.
            let mounted = FileManager.default.fileExists(atPath: WrappLayout(app: context.tree).driveC.appendingPathComponent("x.txt").path)
            calls.withLock { $0.append("program \(program.program) \(mounted ? "with" : "without") its mount") }
            return 0
        }
        func finish() async { finished.withLock { $0 = true } }
    }

    private func step(_ instruction: String, module: String? = nil, options: [String: [String]] = [:], _ arguments: String...) -> PlannedStep {
        PlannedStep(instruction: instruction, module: module, options: options, arguments: arguments, name: options["name"]?.first,
                    origin: "Wrappfile:1")
    }

    private func tree() throws -> URL {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: WrappLayout(app: tree).driveC, withIntermediateDirectories: true)
        return tree
    }

    private func run(_ steps: [PlannedStep], executor: FakeExecutor = FakeExecutor(), inputs: [String: URL] = [:],
                     files: [String: URL] = [:], answer: StepAnswer = .no, recorder: Recorder = Recorder(), in tree: URL) async throws {
        var plan = BuildPlan(edition: "x", stages: [PlannedStage(name: "only", from: .scratch, modules: ["fake"], steps: steps)])
        plan.files = files
        let configuration = RunnerConfiguration(
            executors: ["fake": executor], inputs: GivenInputs(inputs), emitter: recorder, ask: { _ in answer },
            fetch: { _, _, _ in throw StepFailure.failed("no downloads here") },
            pathTypes: PathTypeRegistry([PathType(name: "fake", module: "fake", roles: [.program], shortForm: nil)]),
            places: shippedPlaces)
        try await PlanRunner(plan: plan, configuration: configuration).run(in: tree)
    }

    @Test("Steps run in order, each through whoever carries it out, and every executor is finished")
    func stepsRunInOrder() async throws {
        let tree = try tree()
        defer { try? FileManager.default.removeItem(at: tree) }
        let executor = FakeExecutor(), recorder = Recorder()
        try await run([step("DO-IT", module: "fake"), step("EDIT", options: ["ini": ["a.b=1"], "create": [""]], "wine:C:/x.ini"),
                       step("DO-IT", module: "fake")], executor: executor, recorder: recorder, in: tree)
        #expect(executor.calls.withLock { $0 } == ["DO-IT", "DO-IT"])
        #expect(executor.finished.withLock { $0 })
        #expect(try String(contentsOf: WrappLayout(app: tree).driveC.appendingPathComponent("x.ini"), encoding: .utf8) == "[a]\nb=1")
        let done = recorder.all.filter { if case .stepDone = $0 { true } else { false } }
        #expect(done.count == 3)
    }

    @Test("A step nobody carries out fails, naming it, and the executors are still finished")
    func anUnknownModuleFails() async throws {
        let tree = try tree()
        defer { try? FileManager.default.removeItem(at: tree) }
        let executor = FakeExecutor()
        await #expect(throws: StepFailure.recipe("Wrappfile:1: nothing carries out OTHER.X in this build")) {
            try await run([step("X", module: "other")], executor: executor, in: tree)
        }
        #expect(executor.finished.withLock { $0 })
    }

    @Test("--on-failure=ask carries on without the step when the person says to, and fails when they don't")
    func onFailureAsks() async throws {
        let tree = try tree()
        defer { try? FileManager.default.removeItem(at: tree) }
        let failing = step("FAIL", module: "fake", options: ["on-failure": ["ask"], "name": ["a-patch"]])
        let recorder = Recorder()
        try await run([failing, step("DO-IT", module: "fake")], answer: .yes, recorder: recorder, in: tree)
        #expect(recorder.all.contains { if case .stepSkipped(let ref, _) = $0 { ref.name == "a-patch" } else { false } })
        await #expect(throws: StepFailure.failed("it failed")) { try await run([failing], answer: .no, in: tree) }
        await #expect(throws: StepFailure.failed("it failed")) { try await run([step("FAIL", module: "fake")], answer: .yes, in: tree) }
    }

    @Test("EDIT fails on a missing file unless --create; --keys-must-exist names what isn't there")
    func editsIni() async throws {
        let tree = try tree()
        defer { try? FileManager.default.removeItem(at: tree) }
        await #expect(throws: StepFailure.failed("Wrappfile:1: wine:C:/a.ini doesn't exist (EDIT --create makes it)")) {
            try await run([step("EDIT", options: ["ini": ["s.k=v"]], "wine:C:/a.ini")], in: tree)
        }
        try "[s]\r\nk=old\r\n".write(to: WrappLayout(app: tree).driveC.appendingPathComponent("a.ini"), atomically: true, encoding: .utf8)
        try await run([step("EDIT", options: ["ini": ["s.k=new"], "keys-must-exist": [""]], "wine:C:/a.ini")], in: tree)
        #expect(try String(contentsOf: WrappLayout(app: tree).driveC.appendingPathComponent("a.ini"), encoding: .utf8) == "[s]\r\nk=new\r\n")
        await #expect(throws: StepFailure.failed("Wrappfile:1: a.ini has no s.gone to change (--keys-must-exist)")) {
            try await run([step("EDIT", options: ["ini": ["s.gone=1"], "keys-must-exist": [""]], "wine:C:/a.ini")], in: tree)
        }
    }

    @Test("COPY merges an input's files into the tree, and a bundle's file into a folder")
    func copies() async throws {
        let tree = try tree(), input = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tree); try? FileManager.default.removeItem(at: input) }
        try FileManager.default.createDirectory(at: input.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: input.appendingPathComponent("sub/a.exe"), atomically: true, encoding: .utf8)
        try "._".write(to: input.appendingPathComponent("._a.exe"), atomically: true, encoding: .utf8)
        try await run([step("COPY", options: ["from": ["input:game"]], ".", "wine:C:/Game/"),
                       step("COPY", "bundle:icon.icns", "/Resources/")],
                      inputs: ["game": input], files: ["bundle:icon.icns": input.appendingPathComponent("sub/a.exe")], in: tree)
        let driveC = WrappLayout(app: tree).driveC
        #expect(FileManager.default.fileExists(atPath: driveC.appendingPathComponent("Game/sub/a.exe").path))
        #expect(!FileManager.default.fileExists(atPath: driveC.appendingPathComponent("Game/._a.exe").path))
        #expect(FileManager.default.fileExists(atPath: WrappLayout(app: tree).resources.appendingPathComponent("a.exe").path))
    }

    @Test("RUN runs its program through its path type's module, its mounts there only while it runs")
    func runsWithMounts() async throws {
        let tree = try tree(), file = FileManager.default.temporaryDirectory.appendingPathComponent("mount-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tree); try? FileManager.default.removeItem(at: file) }
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let executor = FakeExecutor()
        try await run([step("RUN", options: ["mount": ["type=bind,source=bundle:x.txt,target=wine:C:/x.txt"]], "fake:setup.exe")],
                      executor: executor, files: ["bundle:x.txt": file], in: tree)
        #expect(executor.calls.withLock { $0 } == ["program fake:setup.exe with its mount"])
        #expect(!FileManager.default.fileExists(atPath: WrappLayout(app: tree).driveC.appendingPathComponent("x.txt").path))
        // A program in no engine is refused.
        await #expect(throws: StepFailure.self) { try await run([step("RUN", "/bin/sh")], in: tree) }
    }

    @Test("A shell RUN runs in the tree's Contents with its mounts and --envs, and can't write outside the tree")
    func runsAShellCommand() async throws {
        let tree = try tree(), outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mount-\(UUID().uuidString).txt")
        defer { for each in [tree, outside, file] { try? FileManager.default.removeItem(at: each) } }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "from the bundle".write(to: file, atomically: true, encoding: .utf8)
        let shell: [String: [String]] = ["shell": [""]]
        try await run([step("RUN", options: shell.merging(["env": ["GREETING=hello there"],
                                                           "mount": ["type=bind,source=bundle:x.txt,target=/x.txt"]]) { $1 },
                            #"echo "$GREETING" > made.txt && cat x.txt | tr a-z A-Z >> made.txt && echo "$HOME" | grep -q run-"#)],
                      files: ["bundle:x.txt": file], in: tree)
        let made = try String(contentsOf: tree.appendingPathComponent("Contents/made.txt"), encoding: .utf8)
        #expect(made == "hello there\nFROM THE BUNDLE")
        #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("Contents/x.txt").path))
        // Outside the tree, it can neither write nor read the person's files.
        let escape = outside.appendingPathComponent("escaped.txt")
        await #expect(throws: StepFailure.failed("Wrappfile:1: the shell command exited with 1")) {
            try await run([step("RUN", options: shell, "echo x > '\(escape.path)'")], in: tree)
        }
        #expect(!FileManager.default.fileExists(atPath: escape.path))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        await #expect(throws: StepFailure.self) { try await run([step("RUN", options: shell, "ls '\(home)'")], in: tree) }
        await #expect(throws: StepFailure.self) { try await run([step("RUN", options: shell, "curl -sf -m 5 https://example.com")], in: tree) }
    }
}

/// Layers kept by the runner and restored by the next build.
struct RunnerLayerTests {
    /// Writes a file per step into the tree, and counts what ran.
    final class Writer: ModuleExecutor {
        static let handles = ["WRITE"]
        let ran = Mutex<[String]>([])
        func run(_ step: PlannedStep, in context: any StepContext) async throws {
            ran.withLock { $0.append(step.arguments[0]) }
            let file = WrappLayout(app: context.tree).resources.appendingPathComponent(step.arguments[0])
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(step.arguments[0].utf8).write(to: file)
        }
    }

    private func write(_ name: String) -> PlannedStep {
        PlannedStep(instruction: "WRITE", module: "fake", options: [:], arguments: [name], name: nil, origin: "Wrappfile:1")
    }

    private func build(_ steps: [PlannedStep], store: LayerStore, executor: Writer, recorder: PlanRunnerTests.Recorder,
                       in folder: URL) async throws -> URL {
        var configuration = RunnerConfiguration(executors: ["fake": executor], emitter: recorder,
                                                fetch: { _, _, _ in throw StepFailure.failed("no downloads") })
        configuration.layers = store
        configuration.layerPolicy = .all
        configuration.suggestsLayer = { _ in true }
        let plan = BuildPlan(edition: "e", stages: [PlannedStage(name: "only", from: .scratch, modules: ["fake"], steps: steps)])
        return try await PlanRunner(plan: plan, configuration: configuration).build(in: folder)
    }

    @Test("A second build restores the deepest layer and runs only what's after it, replaying what the layer kept")
    func restoresTheDeepestLayer() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("layers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = LayerStore(root: scratch.appendingPathComponent("store"))
        let first = Writer()
        _ = try await build([write("a"), write("b")], store: store, executor: first, recorder: .init(), in: scratch.appendingPathComponent("one"))
        #expect(first.ran.withLock { $0 } == ["a", "b"])

        // The same steps: everything restored.
        let second = Writer(), recorder = PlanRunnerTests.Recorder()
        let tree = try await build([write("a"), write("b")], store: store, executor: second, recorder: recorder, in: scratch.appendingPathComponent("two"))
        #expect(second.ran.withLock { $0 }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: WrappLayout(app: tree).resources.appendingPathComponent("b").path))
        #expect(recorder.all.contains { if case .replayed(.stepDone) = $0 { true } else { false } })

        // A changed second step: the first restored, the second run again.
        let third = Writer()
        _ = try await build([write("a"), write("c")], store: store, executor: third, recorder: .init(), in: scratch.appendingPathComponent("three"))
        #expect(third.ran.withLock { $0 } == ["c"])

        // A changed first step changes every key after it.
        let fourth = Writer()
        _ = try await build([write("z"), write("c")], store: store, executor: fourth, recorder: .init(), in: scratch.appendingPathComponent("four"))
        #expect(fourth.ran.withLock { $0 } == ["z", "c"])
    }

    /// Inputs a person would be asked for: counted when asked for.
    final class AskingInputs: InputProvider, @unchecked Sendable {
        let folder: URL
        let asked = Mutex<[String]>([])
        init(_ folder: URL) { self.folder = folder }
        func input(_ name: String) async throws -> URL {
            asked.withLock { $0.append(name) }
            return folder
        }
        func inputIfReady(_ name: String) async throws -> URL? { nil }
    }

    @Test("Keying a build asks for no input: one that isn't to hand is keyed as such, and asked for when its step runs")
    func keysAskForNothing() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("layers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("disc"), withIntermediateDirectories: true)
        let inputs = AskingInputs(scratch.appendingPathComponent("disc"))
        final class Reader: ModuleExecutor {
            static let handles = ["READ"]
            let inputs: AskingInputs
            init(_ inputs: AskingInputs) { self.inputs = inputs }
            func run(_ step: PlannedStep, in context: any StepContext) async throws { _ = try await context.input("disc-2") }
        }
        var configuration = RunnerConfiguration(executors: ["fake": Reader(inputs)], inputs: inputs, emitter: PlanRunnerTests.Recorder(),
                                                fetch: { _, _, _ in throw StepFailure.failed("no downloads") })
        configuration.layers = LayerStore(root: scratch.appendingPathComponent("store"))
        configuration.layerPolicy = .all
        let step = PlannedStep(instruction: "READ", module: "fake", options: [:], arguments: [PlannedStep.inputToken("disc-2")],
                               name: nil, origin: "Wrappfile:1")
        let plan = BuildPlan(edition: "e", stages: [PlannedStage(name: "only", from: .scratch, modules: ["fake"], steps: [step])])
        let keys = try await StepKeys.make(for: plan, configuration: configuration, trees: ["only": scratch.appendingPathComponent("t.app")])
        #expect(inputs.asked.withLock { $0 }.isEmpty)
        #expect(keys.keys["only"]?.first?.inputs.contains(LayerKey.Input("input disc-2", "given when needed")) == true)
        _ = try await PlanRunner(plan: plan, configuration: configuration).build(in: scratch.appendingPathComponent("build"))
        #expect(inputs.asked.withLock { $0 } == ["disc-2"])
    }

    @Test("An ENGINE step's key is its prepared engine's: one prepared again at the same version is a fresh layer")
    func engineKey() async throws {
        func key(_ hash: String) async throws -> LayerKey? {
            var configuration = RunnerConfiguration(emitter: PlanRunnerTests.Recorder(), fetch: { _, _, _ in throw StepFailure.failed("no downloads") })
            configuration.layers = LayerStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("layers-\(UUID().uuidString)"))
            configuration.engine = { module, version in
                EngineStore.Engine(module: module, version: version, hash: hash, tree: URL(fileURLWithPath: "/"), prepared: false)
            }
            let step = PlannedStep(instruction: "ENGINE", module: nil, options: [:], arguments: ["wine@10.0_8"], name: nil, origin: "x", setup: true)
            let plan = BuildPlan(edition: "e", stages: [PlannedStage(name: "only", from: .scratch, modules: [], steps: [step])])
            return try await StepKeys.make(for: plan, configuration: configuration, trees: [:]).keys["only"]?.first
        }
        #expect(try await key("a") == key("a"))
        #expect(try await key("a")?.hash != key("b")?.hash)
    }
}
