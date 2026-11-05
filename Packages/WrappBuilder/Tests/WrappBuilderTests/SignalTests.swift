import Foundation
import Synchronization
import Testing
@testable import WrappBuilder
import WrappFormat
import WrappModules

/// Signals: `SIGNAL`/`WATCH` parsed and planned, a step watching for its
/// own, the watcher, and `EMIT --on` listeners.
struct SignalTests {
    @Test("SIGNAL holds WATCH lines, and says how more than one combine")
    func parsing() throws {
        let file = try WrappfileParser.parse("""
            SIGNAL copying
              WATCH --log="C:/setup.log" --matches="Copying (?<done>\\\\d+) of (?<total>\\\\d+)"
            END
            SIGNAL ready --any
              WATCH --file=C:/done.txt
              WATCH --process=game.exe
            END
            FROM scratch
            """)
        #expect(file.signals.map(\.name) == ["copying", "ready"])
        #expect(file.signals[1].combine == .any)
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse("SIGNAL a\n  WATCH --file=x\n  WATCH --file=y\nEND\n") }
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse("SIGNAL a\nEND\n") }
        #expect(throws: WrappfileError.self) { try WrappfileParser.parse("FROM scratch\nWATCH --file=x\n") }
    }

    @Test("A disc's install watches for the installer module's alive signal unless it names another")
    func installerDefault() throws {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/white-wolf")).get()
        let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        let plan = try #require(try BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            .plan(edition: "cd", conditions: BuildConditions(arch: "arm64", macos: 15)))
        let install = try #require(plan.stages.flatMap(\.steps).first { $0.module == "installer" && $0.instruction == "RUN" && !$0.has("patch") })
        #expect(install.option("alive") == "installer.alive")
        let alive = try #require(plan.signals["installer.alive"])
        #expect(alive.combine == .any)
        #expect(alive.watches.contains(.module(id: "wine", watch: "busy", value: nil)))
        #expect(alive.watches.contains(.grows(path: "wine:C:/Program Files (x86)")))
        #expect(alive.watches.contains(.log(path: "${program.log}", pattern: .matches("."))))
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("The watcher hears a log's new lines, a file appearing and a folder growing, with their fields")
    func watcher() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("setup.log")
        try Data("before\n".utf8).write(to: log)
        let signals = [
            PlannedSignal(name: "copying", combine: .all, watches: [.log(path: "${program.log}", pattern: .matches("Copying (?<done>\\d+) of (?<total>\\d+)"))]),
            PlannedSignal(name: "done", combine: .all, watches: [.file(path: "done")]),
            PlannedSignal(name: "grows", combine: .all, watches: [.grows(path: "folder")]),
        ]
        let fired = Mutex<[(String, [String: String])]>([])
        let watcher = SignalWatcher(signals: signals, resolve: { root.appendingPathComponent($0) },
                                    onFire: { name, fields in fired.withLock { $0.append((name, fields)) } })
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        watcher.program(WatchedProgram(path: "/x/setup.exe", log: log.path))
        watcher.poll()
        #expect(fired.withLock { $0 }.isEmpty, "Nothing has happened yet")

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("Copying 3 of 10\n".utf8))
        try handle.close()
        try Data().write(to: root.appendingPathComponent("done"))
        try Data("x".utf8).write(to: root.appendingPathComponent("folder/file"))
        watcher.poll()
        let all = fired.withLock { $0 }
        #expect(all.first { $0.0 == "copying" }?.1 == ["done": "3", "total": "10"])
        #expect(all.first { $0.0 == "done" }?.1["path"] != nil)
        #expect(all.first { $0.0 == "grows" }?.1 == ["size": "1"])

        // Nothing new: nothing fires again.
        fired.withLock { $0 = [] }
        watcher.poll()
        #expect(fired.withLock { $0 }.isEmpty)
    }

    @Test("--all fires once each watch has, --any on each")
    func combining() {
        let fired = Mutex<[String]>([])
        let signals = [
            PlannedSignal(name: "both", combine: .all, watches: [.output(pattern: .contains("a")), .output(pattern: .contains("b"))]),
            PlannedSignal(name: "either", combine: .any, watches: [.output(pattern: .contains("a")), .output(pattern: .contains("b"))]),
        ]
        let watcher = SignalWatcher(signals: signals, resolve: { _ in nil }, onFire: { name, _ in fired.withLock { $0.append(name) } })
        watcher.output("a")
        watcher.poll()
        #expect(fired.withLock { $0 } == ["either"])
        watcher.output("b")
        watcher.poll()
        #expect(fired.withLock { $0 } == ["either", "both", "either"])
    }

    /// An executor whose step writes lines to its program's output.
    struct Writer: ModuleExecutor {
        static let handles = ["WRITE"]
        func run(_ step: PlannedStep, in context: any StepContext) async throws {
            context.watch(program: WatchedProgram(path: "/x/setup.exe"))
            for line in ["Copying 1 of 2", "Copying 2 of 2"] {
                context.programWrote(line)
                try await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    @Test("EMIT --on emits as its signal fires, while steps run, until EMIT --off")
    func listeners() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree.app")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let write = PlannedStep(instruction: "WRITE", module: "fake", options: [:], arguments: [], name: nil, origin: "W:3")
        var plan = BuildPlan(edition: "x", stages: [PlannedStage(name: "only", from: .scratch, modules: ["fake"], steps: [write, write],
            emits: [PlannedEmit(before: 0, text: "copied ${signal.done}/${signal.total} by ${program.name}", origin: "W:2", on: "copying"),
                    PlannedEmit(before: 1, text: "", origin: "W:4", off: "copying")])])
        plan.signals = ["copying": PlannedSignal(name: "copying", combine: .all,
                                                 watches: [.output(pattern: .matches("Copying (?<done>\\d+) of (?<total>\\d+)"))])]
        let recorder = PlanRunnerTests.Recorder()
        let configuration = RunnerConfiguration(executors: ["fake": Writer()], emitter: recorder,
                                                fetch: { _, _, _ in throw StepFailure.failed("no downloads") }, pathTypes: PathTypeRegistry([]))
        try await PlanRunner(plan: plan, configuration: configuration).run(in: tree)
        let emitted = recorder.all.compactMap { event -> String? in
            if case .emitted(let text) = event { return text }
            return nil
        }
        // The first step's two lines; nothing from the second, after --off.
        #expect(emitted == ["copied 1/2 by setup.exe", "copied 2/2 by setup.exe"])
    }
}
