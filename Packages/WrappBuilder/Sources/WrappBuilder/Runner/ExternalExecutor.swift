//
//  ExternalExecutor.swift
//  WrappBuilder
//
//  A module's program as an executor (decisions 7 and 8 of the builders
//  plan; docs/module-programs.md): started when a step first needs it, for
//  the rest of the build, and asked over the module protocol.

import Foundation
import Logging
import WrappFormat
import ProcessKit
import Synchronization

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ModuleProgram")

/// Forwards each `ModuleExecutor` call to a module's program, and answers
/// the program's `StepContext` calls with the step it's running. The runner
/// can't tell it from an executor compiled in.
public nonisolated final class ExternalExecutor: ModuleExecutor {
    /// Its program's instructions are its module's `build:`'s, which the
    /// checker reads; the program says them again in `hello`.
    public static let handles: [String] = []

    public let module: String
    public let release: Int
    public let program: URL

    private struct Running {
        var process: Process
        var connection: RPCConnection
        var handles: [String]
    }

    private let running = Mutex<Running?>(nil)
    /// The step the program is carrying out, whose context answers its calls.
    private let current = Mutex<(any StepContext)?>(nil)
    private let starting = Mutex<Task<Running, Error>?>(nil)

    public init(module: String, release: Int, program: URL) {
        self.module = module
        self.release = release
        self.program = program
    }

    /// The program's hash, so a new build of it means fresh layers; then
    /// what it adds itself.
    public func keyInputs(for step: PlannedStep, in context: any StepContext) async throws -> KeyInputs {
        let hash = try await Blocking.run { [program] in try LayerKey.hash(file: program) }
        let own = try await call("keyInputs", step: step, context: context, as: KeyInputs.self)
        return KeyInputs([KeyInput("program", hash)] + own.inputs)
    }

    public func run(_ step: PlannedStep, in context: any StepContext) async throws {
        _ = try await call("run", step: step, context: context, as: Nothing?.self)
    }

    public func checkpoint(_ context: any StepContext) async throws {
        guard running.withLock({ $0 != nil }) else { return }
        _ = try await call("checkpoint", step: PlannedStep(instruction: "CHECKPOINT", module: module, options: [:], arguments: [],
                                                           name: nil, origin: module), context: context, as: Nothing?.self)
    }

    public func finish() async {
        guard let running = running.withLock({ $0 }) else { return }
        _ = try? await running.connection.request("finish", Nothing(), as: Nothing?.self)
        let process = running.process
        // A program that doesn't end by itself once finished is ended.
        let deadline = ContinuousClock.now + .seconds(10)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning {
            logger.warning("\(module)'s program was still running 10s after finishing: ending it")
            process.terminate()
        }
        running.connection.close()
        self.running.withLock { $0 = nil }
        // A later call starts it again.
        starting.withLock { $0 = nil }
    }

    /// Start the program and agree a protocol with it: what importing one
    /// checks.
    public func greet() async throws { _ = try await started() }

    /// `method` for `step`, with `context` answering the program's calls
    /// until it replies.
    private func call<R: Decodable>(_ method: String, step: PlannedStep, context: any StepContext, as type: R.Type) async throws -> R {
        let running = try await started()
        current.withLock { $0 = context }
        defer { current.withLock { $0 = nil } }
        let signals = InstructionSpec.signalOptions.filter { context.hasSignal($0) }.sorted()
        return try await running.connection.request(method, RemoteStep(step: step, tree: context.tree.path, signals: signals), as: type)
    }

    /// The program, started and greeted, once.
    private func started() async throws -> Running {
        if let running = running.withLock({ $0 }) { return running }
        let task = starting.withLock { starting -> Task<Running, Error> in
            if let starting { return starting }
            let task = Task { try await self.start() }
            starting = task
            return task
        }
        let running = try await task.value
        self.running.withLock { $0 = running }
        return running
    }

    /// Writing to a program that has ended raises SIGPIPE, which would end
    /// the build's process: ignored, so the write fails instead.
    private static let ignoringBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// What a module's program may do (decision 10 of the builders plan;
    /// docs/module-programs.md#the-sandbox): read as the person can, but
    /// reach no network and write only to the temporary folder, where the
    /// build's trees and session stores are, and the cache stores. What it
    /// needs from outside it asks the build for (`input`, `fetch`). A
    /// profile's paths are real ones: `/private/var/…`, not `/var/…`.
    static let sandboxProfile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath (param "TEMP")) (subpath (param "CACHE_STORES"))
               (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))
        """

    /// `sandbox-exec` and its arguments, which start `program` in the
    /// sandbox; nil with `SECOND_CHANCE_MODULE_SANDBOX=0`, or where macOS
    /// has no `sandbox-exec`.
    static func sandboxed(_ program: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> (URL, [String])? {
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard environment["SECOND_CHANCE_MODULE_SANDBOX"] != "0", FileManager.default.isExecutableFile(atPath: sandbox.path) else { return nil }
        let temp = realPath(FileManager.default.temporaryDirectory)
        let stores = realPath(StoreLocations.realCaches.appendingPathComponent("SecondChance/stores"))
        return (sandbox, ["-p", sandboxProfile, "-D", "TEMP=\(temp)", "-D", "CACHE_STORES=\(stores)", program.path])
    }

    /// `url`'s path with every link resolved, as the sandbox matches it
    /// (`URL.resolvingSymlinksInPath` takes `/private` off again): as far as
    /// it exists, the rest as written.
    static func realPath(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }
        return (realPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    private func start() async throws -> Running {
        _ = Self.ignoringBrokenPipes
        let process = Process()
        if let (sandbox, arguments) = Self.sandboxed(program) {
            process.executableURL = sandbox
            process.arguments = arguments
        } else {
            let why = ProcessInfo.processInfo.environment["SECOND_CHANCE_MODULE_SANDBOX"] == "0"
                ? "SECOND_CHANCE_MODULE_SANDBOX=0" : "this Mac has no sandbox-exec"
            logger.warning("[\(module)] Its program runs unsandboxed: \(why)")
            process.executableURL = program
        }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let module = module
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) { logger.notice("[\(module)] \(line)") }
        }
        do {
            try process.run()
        } catch {
            throw StepFailure.failed("\(module)'s program couldn't start: \(error.localizedDescription)")
        }
        let connection = RPCConnection(input: output.fileHandleForReading, output: input.fileHandleForWriting)
        connection.setHandler { [weak self] method, params in
            guard let self else { throw RPCError(.failed, "the build has finished") }
            return try await self.answer(method, params, connection: connection)
        }
        let hello = try await connection.request("hello", Hello(protocol: ModuleProtocol.version, module: module, release: release),
                                                 as: Hello.self)
        guard hello.protocol <= ModuleProtocol.version else {
            process.terminate()
            throw StepFailure.recipe("\(module)'s program speaks module protocol \(hello.protocol), newer than this build's "
                + "\(ModuleProtocol.version): update Second Chance")
        }
        logger.notice("Started \(module)'s program (protocol \(hello.protocol)), which carries out \((hello.handles ?? []).joined(separator: ", "))")
        return Running(process: process, connection: connection, handles: hello.handles ?? [])
    }

    /// One of the program's calls, answered by the step it's carrying out.
    private func answer(_ method: String, _ params: Data?, connection: RPCConnection) async throws -> Data? {
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            guard let params else { throw RPCError(.invalidParams, "\(method) has no params") }
            return try JSONDecoder().decode(type, from: params)
        }
        func path(_ url: URL?) throws -> Data { try JSONEncoder().encode(Path(path: url?.path)) }
        guard let context = current.withLock({ $0 }) else {
            throw RPCError(.failed, "\(method) came while the program carries out no step")
        }
        switch method {
        case "tree": return try path(context.tree(ofStage: try decode(Named.self).name))
        case "file": return try path(context.file(try decode(Named.self).name))
        case "moduleFile":
            let file = try decode(ModuleFile.self)
            return try path(context.moduleFile(file.module, file.path))
        case "input": return try path(try await context.input(try decode(Named.self).name))
        case "inputIfGiven": return try path(try await context.inputIfGiven(try decode(Named.self).name))
        case "ask": return try JSONEncoder().encode(try await context.ask(try decode(StepQuestion.self)))
        case "runProgram":
            let run = try decode(RunProgram.self)
            return try JSONEncoder().encode(Exit(exit: try await context.runProgram(run.program, mounts: run.mounts)))
        case "fetch":
            let fetch = try decode(Fetch.self)
            guard let url = URL(string: fetch.url) else { throw RPCError(.invalidParams, "fetch's url isn't one: \(fetch.url)") }
            return try path(try await context.fetch(url: url, sha256: fetch.sha256))
        case "store": return try path(try await context.store(try decode(Named.self).name))
        case "watch": context.watch(program: try decode(WatchedProgram.self))
        case "programWrote": context.programWrote(try decode(Line.self).line)
        case "programExited": context.programExited(try decode(Exit.self).exit)
        case "onSignal":
            let option = try decode(Named.self).name
            context.onSignal(option) { fields in connection.notify("signal", SignalFired(option: option, fields: fields)) }
        case "emit": context.emitter.emit(try decode(BuildEvent.self))
        case "log":
            let line = try decode(LogLine.self)
            context.log.log(level: Logger.Level(rawValue: line.level) ?? .notice, "[\(module)] \(line.message)")
        default:
            throw RPCError(.methodNotFound, "the build has no \(method)")
        }
        return nil
    }
}
