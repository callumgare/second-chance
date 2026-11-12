//
//  ModuleProtocol.swift
//  WrappModuleKit
//
//  The module protocol (decision 8 of the builders plan;
//  docs/module-programs.md): JSON-RPC 2.0, a message a line, on a module
//  program's stdin and stdout. Either side asks; `StepContext` and
//  `ModuleExecutor` on the wire, and nothing more.

import Foundation
import Logging
import Synchronization

/// The protocol's version, which `hello` agrees.
public nonisolated enum ModuleProtocol {
    public static let version = 1

    /// The calls a program is asked (`ModuleExecutor`'s), and those the
    /// build answers (`StepContext`'s): what the schema and its test hold
    /// both protocols to.
    public static let programMethods = ["hello", "keyInputs", "run", "runProgram", "checkpoint", "finish"]
    public static let buildMethods = ["tree", "file", "input", "inputIfGiven", "moduleFile", "ask", "runProgram", "fetch", "store",
                                      "watch", "programWrote", "programExited", "onSignal", "emit", "log"]

    /// JSON-RPC's and the protocol's error codes.
    public enum ErrorCode: Int, Sendable {
        case methodNotFound = -32601
        case invalidParams = -32602
        /// A recipe problem: `StepFailure.recipe`.
        case recipe = -32000
        /// The step failed: `StepFailure.failed`.
        case failed = -32001
        /// LSP's, for a cancelled request.
        case cancelled = -32800
    }
}

/// A JSON-RPC error, as one side sends the other.
public nonisolated struct RPCError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ code: ModuleProtocol.ErrorCode, _ message: String) {
        self.init(code: code.rawValue, message: message)
    }

    public var description: String { message }

    /// What an error is on the wire: a step's failure by its kind, a cancel
    /// as LSP's, anything else as a failure with its description.
    public init(_ error: Error) {
        switch error {
        case let error as RPCError: self = error
        case StepFailure.recipe(let message): self.init(.recipe, message)
        case StepFailure.failed(let message): self.init(.failed, message)
        case is CancellationError: self.init(.cancelled, "cancelled")
        default: self.init(.failed, String(describing: error))
        }
    }

    /// The error it stands for on this side.
    public var asError: Error {
        switch code {
        case ModuleProtocol.ErrorCode.recipe.rawValue: StepFailure.recipe(message)
        case ModuleProtocol.ErrorCode.cancelled.rawValue: CancellationError()
        default: StepFailure.failed(message)
        }
    }
}

/// One message: a request (`id` and `method`), a notification (`method`
/// alone), or a reply (`id` with `result` or `error`). Params and results
/// are JSON, carried as text and decoded to the type each call takes.
nonisolated struct RPCMessage: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?
    var method: String?
    var params: RawJSON?
    var result: RawJSON?
    var error: RPCError?
}

/// JSON kept as it was, decoded when its type is known.
nonisolated struct RawJSON: Codable, Sendable {
    let data: Data

    init<T: Encodable>(_ value: T) throws { data = try JSONEncoder().encode(value) }
    init(data: Data) { self.data = data }

    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data) }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(AnyJSON.self)
        data = try JSONSerialization.data(withJSONObject: value.object, options: [.fragmentsAllowed])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(AnyJSON(object: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])))
    }
}

/// Any JSON value, for `RawJSON`'s way through a `Codable` message.
nonisolated struct AnyJSON: Codable {
    let object: Any

    init(object: Any) { self.object = object }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            object = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            object = bool
        } else if let int = try? container.decode(Int64.self) {
            object = int
        } else if let double = try? container.decode(Double.self) {
            object = double
        } else if let string = try? container.decode(String.self) {
            object = string
        } else if let array = try? container.decode([AnyJSON].self) {
            object = array.map(\.object)
        } else {
            object = try container.decode([String: AnyJSON].self).mapValues(\.object)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch object {
        case is NSNull: try container.encodeNil()
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): try container.encode(number.boolValue)
        case let int as Int64: try container.encode(int)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map(AnyJSON.init(object:)))
        case let dictionary as [String: Any]: try container.encode(dictionary.mapValues(AnyJSON.init(object:)))
        default: try container.encodeNil()
        }
    }
}

/// Nothing, as params or a result.
public nonisolated struct Nothing: Codable, Sendable {
    public init() {}
}

/// One end of the protocol: reads a message a line from `input`, answers
/// each request through `handler` (concurrently), matches each reply to the
/// request it answers, and writes a message a line to `output`.
///
/// A notification is handled in order, on the reader, and finished before
/// the next message is read, so what the other end says before a reply has
/// been heard when its request returns: a program's `emit`s before its
/// step's reply belong to the step. When each was a task of its own, a
/// step could be done before its last `emit` was handled. Requests run
/// concurrently, since one may wait on the other end (`input`, `ask`); a
/// notification's handler must not.
public nonisolated final class RPCConnection: Sendable {
    public typealias Handler = @Sendable (_ method: String, _ params: Data?) async throws -> Data?

    private let output: FileHandle
    private let writing = Mutex(())
    private let pending = Mutex<[Int: CheckedContinuation<Data?, Error>]>([:])
    private let nextID = Atomic<Int>(1)
    private let handler: Mutex<Handler?>
    private let reader = Mutex<Task<Void, Never>?>(nil)
    /// Called once the other end has gone.
    private let onClose = Mutex<(@Sendable () -> Void)?>(nil)
    /// The other end's requests being answered, by id, and those answered
    /// before they could be registered.
    private let running = Mutex<(tasks: [Int: Task<Void, Never>], finished: Set<Int>)>(([:], []))
    /// How long a cancelled request waits for its answer before giving up
    /// (decision 8 of the builders plan: 10 s).
    private let cancelGrace: Duration
    /// Called when a cancelled request went unanswered for `cancelGrace`:
    /// the other end is to be ended.
    private let onUnanswered = Mutex<(@Sendable () -> Void)?>(nil)

    public init(input: FileHandle, output: FileHandle, handler: Handler? = nil, cancelGrace: Duration = .seconds(10)) {
        self.output = output
        self.cancelGrace = cancelGrace
        self.handler = Mutex(handler)
        let task = Task.detached { [weak self] in
            do {
                for try await line in input.bytes.lines {
                    guard let self else { return }
                    await self.received(line)
                }
            } catch {}
            self?.closed()
        }
        reader.withLock { $0 = task }
    }

    public func setHandler(_ handler: @escaping Handler) { self.handler.withLock { $0 = handler } }
    public func whenClosed(_ action: @escaping @Sendable () -> Void) { onClose.withLock { $0 = action } }
    public func whenCancelUnanswered(_ action: @escaping @Sendable () -> Void) { onUnanswered.withLock { $0 = action } }

    /// Ask the other end, waiting for its reply.
    public func request<P: Encodable, R: Decodable>(_ method: String, _ params: P, as result: R.Type) async throws -> R {
        let id = nextID.wrappingAdd(1, ordering: .relaxed).oldValue
        let data: Data? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock { $0[id] = continuation }
                do {
                    try send(RPCMessage(id: id, method: method, params: try RawJSON(params)))
                } catch {
                    if let waiting = pending.withLock({ $0.removeValue(forKey: id) }) { waiting.resume(throwing: error) }
                }
            }
        } onCancel: {
            try? self.send(RPCMessage(method: "$/cancelRequest", params: try? RawJSON(["id": id])))
            // One that doesn't answer in time is given up on, and its end
            // told to go, so a cancel never waits for ever.
            let grace = self.cancelGrace
            Task.detached { [weak self] in
                try? await Task.sleep(for: grace)
                guard let self, let waiting = self.pending.withLock({ $0.removeValue(forKey: id) }) else { return }
                waiting.resume(throwing: CancellationError())
                self.onUnanswered.withLock { $0 }?()
            }
        }
        return try JSONDecoder().decode(R.self, from: data ?? Data("null".utf8))
    }

    /// Tell the other end, expecting no reply.
    public func notify<P: Encodable>(_ method: String, _ params: P) {
        do {
            try send(RPCMessage(method: method, params: try RawJSON(params)))
        } catch {
            // The other end has gone; what it would have been told no longer matters.
        }
    }

    private func send(_ message: RPCMessage) throws {
        var line = try JSONEncoder().encode(message)
        line.append(UInt8(ascii: "\n"))
        try writing.withLock { _ in try output.write(contentsOf: line) }
    }

    private func received(_ line: String) async {
        guard let message = try? JSONDecoder().decode(RPCMessage.self, from: Data(line.utf8)) else { return }
        if let method = message.method {
            if method == "$/cancelRequest" {
                if let id = try? message.params?.decode([String: Int].self)["id"] {
                    running.withLock { $0.tasks[id] }?.cancel()
                }
                return
            }
            let handler = handler.withLock { $0 }
            guard let id = message.id else {
                // A notification: in order, before anything after it.
                _ = try? await handler?(method, message.params?.data)
                return
            }
            let task = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    guard let handler else { throw RPCError(.methodNotFound, "nothing answers \(method)") }
                    let result = try await handler(method, message.params?.data)
                    try? self.send(RPCMessage(id: id, result: RawJSON(data: result ?? Data("null".utf8))))
                } catch {
                    try? self.send(RPCMessage(id: id, error: RPCError(error)))
                }
                // One that ends before it's registered is noted, so it isn't
                // registered after.
                self.running.withLock { running in
                    if running.tasks.removeValue(forKey: id) == nil { running.finished.insert(id) }
                }
            }
            running.withLock { running in
                if running.finished.remove(id) == nil { running.tasks[id] = task }
            }
            return
        }
        guard let id = message.id, let waiting = pending.withLock({ $0.removeValue(forKey: id) }) else { return }
        if let error = message.error {
            waiting.resume(throwing: error.asError)
        } else {
            waiting.resume(returning: message.result?.data)
        }
    }

    private func closed() {
        let waiting = pending.withLock { pending in defer { pending = [:] }; return pending }
        for continuation in waiting.values { continuation.resume(throwing: StepFailure.failed("the module's program ended")) }
        onClose.withLock { $0 }?()
    }

    /// Stop reading.
    public func close() { reader.withLock { $0 }?.cancel() }
}

// MARK: - The messages' params

/// `hello`'s, each way.
public nonisolated struct Hello: Codable, Sendable {
    public var `protocol`: Int
    public var module: String?
    public var release: Int?
    public var handles: [String]?

    public init(protocol: Int, module: String? = nil, release: Int? = nil, handles: [String]? = nil) {
        self.protocol = `protocol`
        self.module = module
        self.release = release
        self.handles = handles
    }
}

/// What a step is run with, on the wire: the step, its tree, and which of
/// its signal options it names.
public nonisolated struct RemoteStep: Codable, Sendable {
    public var step: PlannedStep
    public var tree: String
    public var signals: [String]

    public init(step: PlannedStep, tree: String, signals: [String]) {
        self.step = step
        self.tree = tree
        self.signals = signals
    }
}

public nonisolated struct Named: Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public nonisolated struct ModuleFile: Codable, Sendable {
    public var module: String
    public var path: String
    public init(module: String, path: String) {
        self.module = module
        self.path = path
    }
}

public nonisolated struct Path: Codable, Sendable {
    public var path: String?
    public init(path: String?) { self.path = path }
}

public nonisolated struct Fetch: Codable, Sendable {
    public var url: String
    public var sha256: String
    public init(url: String, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }
}

public nonisolated struct RunProgram: Codable, Sendable {
    public var program: ProgramRun
    public var mounts: [String]
    public init(program: ProgramRun, mounts: [String]) {
        self.program = program
        self.mounts = mounts
    }
}

public nonisolated struct Exit: Codable, Sendable {
    public var exit: Int32
    public init(exit: Int32) { self.exit = exit }
}

public nonisolated struct Line: Codable, Sendable {
    public var line: String
    public init(line: String) { self.line = line }
}

public nonisolated struct SignalFired: Codable, Sendable {
    public var option: String
    public var fields: [String: String]
    public init(option: String, fields: [String: String]) {
        self.option = option
        self.fields = fields
    }
}

public nonisolated struct LogLine: Codable, Sendable {
    public var level: String
    public var message: String
    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

// MARK: - The program's side

/// What a module's program runs: `try await ModuleProgram.serve(MyModule())`
/// in its `main.swift`, which answers the build on stdin and stdout until
/// it's told to finish or the build goes.
public nonisolated enum ModuleProgram {
    public static func serve(_ executor: some ModuleExecutor, input: FileHandle = .standardInput,
                             output: FileHandle = .standardOutput) async throws {
        let connection = RPCConnection(input: input, output: output)
        let done = AsyncStream<Void>.makeStream()
        connection.whenClosed { done.continuation.finish() }
        let signals = SignalHandlers()
        connection.setHandler { method, params in
            func decode<T: Decodable>(_ type: T.Type) throws -> T {
                guard let params else { throw RPCError(.invalidParams, "\(method) has no params") }
                return try JSONDecoder().decode(type, from: params)
            }
            func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
            switch method {
            case "hello":
                return try encode(Hello(protocol: ModuleProtocol.version, handles: type(of: executor).handles))
            case "keyInputs":
                let remote = try decode(RemoteStep.self)
                return try encode(try await executor.keyInputs(for: remote.step, in: RemoteStepContext(connection, remote, signals)))
            case "run":
                let remote = try decode(RemoteStep.self)
                try await executor.run(remote.step, in: RemoteStepContext(connection, remote, signals))
                return nil
            case "runProgram":
                let run = try decode(RunProgram.self)
                let remote = RemoteStep(step: run.program.step, tree: run.mounts.first ?? "/", signals: [])
                return try encode(Exit(exit: try await executor.runProgram(run.program, in: RemoteStepContext(connection, remote, signals))))
            case "checkpoint":
                let remote = try decode(RemoteStep.self)
                try await executor.checkpoint(RemoteStepContext(connection, remote, signals))
                return nil
            case "finish":
                await executor.finish()
                done.continuation.finish()
                return nil
            case "signal":
                let fired = try decode(SignalFired.self)
                signals.fire(fired.option, fired.fields)
                return nil
            default:
                throw RPCError(.methodNotFound, "a module's program has no \(method)")
            }
        }
        for await _ in done.stream {}
        // Its reply to `finish` written before it ends.
        try await Task.sleep(for: .milliseconds(100))
    }
}

/// A `StepContext` that asks the build for everything: what a module's
/// program's executor is given.
nonisolated final class RemoteStepContext: StepContext {
    let connection: RPCConnection
    let remote: RemoteStep
    let signals: SignalHandlers
    let log: Logger

    init(_ connection: RPCConnection, _ remote: RemoteStep, _ signals: SignalHandlers) {
        self.connection = connection
        self.remote = remote
        self.signals = signals
        var logger = Logger(label: "module-program") { _ in RemoteLogHandler(connection: connection) }
        logger.logLevel = .debug
        log = logger
    }

    var tree: URL { URL(fileURLWithPath: remote.tree) }
    var emitter: any EventEmitter { RemoteEmitter(connection: connection) }

    /// A call the protocol makes as one waited for: the few of
    /// `StepContext`'s that aren't `async`.
    private func waiting<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, _ params: P, as type: R.Type) -> R? {
        let result = Mutex<R?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let connection = connection
        Task.detached {
            let value = try? await connection.request(method, params, as: type)
            result.withLock { $0 = value }
            semaphore.signal()
        }
        semaphore.wait()
        return result.withLock { $0 }
    }

    func tree(ofStage name: String) -> URL? { waiting("tree", Named(name: name), as: Path.self)?.path.map(URL.init(fileURLWithPath:)) }
    func file(_ fullForm: String) -> URL? { waiting("file", Named(name: fullForm), as: Path.self)?.path.map(URL.init(fileURLWithPath:)) }
    func location(of fullForm: String) -> URL? {
        waiting("location", Named(name: fullForm), as: Path.self)?.path.map(URL.init(fileURLWithPath:))
    }
    func moduleFile(_ module: String, _ path: String) -> URL? {
        waiting("moduleFile", ModuleFile(module: module, path: path), as: Path.self)?.path.map(URL.init(fileURLWithPath:))
    }

    func input(_ name: String) async throws -> URL {
        guard let path = try await connection.request("input", Named(name: name), as: Path.self).path else {
            throw StepFailure.recipe("the build has no input \(name)")
        }
        return URL(fileURLWithPath: path)
    }

    func inputIfGiven(_ name: String) async throws -> URL? {
        try await connection.request("inputIfGiven", Named(name: name), as: Path.self).path.map(URL.init(fileURLWithPath:))
    }

    func ask(_ question: StepQuestion) async throws -> StepAnswer { try await connection.request("ask", question, as: StepAnswer.self) }

    func runProgram(_ program: ProgramRun, mounts: [String]) async throws -> Int32 {
        try await connection.request("runProgram", RunProgram(program: program, mounts: mounts), as: Exit.self).exit
    }

    func fetch(url: URL, sha256: String) async throws -> URL {
        guard let path = try await connection.request("fetch", Fetch(url: url.absoluteString, sha256: sha256), as: Path.self).path else {
            throw StepFailure.failed("the build fetched nothing from \(url)")
        }
        return URL(fileURLWithPath: path)
    }

    func store(_ name: String) async throws -> URL {
        guard let path = try await connection.request("store", Named(name: name), as: Path.self).path else {
            throw StepFailure.recipe("the build has no store \(name)")
        }
        return URL(fileURLWithPath: path)
    }

    func watch(program: WatchedProgram) { connection.notify("watch", program) }
    func programWrote(_ line: String) { connection.notify("programWrote", Line(line: line)) }
    func programExited(_ code: Int32) { connection.notify("programExited", Exit(exit: code)) }

    func onSignal(_ option: String, _ handler: @escaping @Sendable ([String: String]) -> Void) {
        signals.add(option, handler)
        connection.notify("onSignal", Named(name: option))
    }

    func hasSignal(_ option: String) -> Bool { remote.signals.contains(option) }
}

/// What a program's executor asked to hear of its step's signals.
nonisolated final class SignalHandlers: Sendable {
    private let handlers = Mutex<[String: [@Sendable ([String: String]) -> Void]]>([:])

    func add(_ option: String, _ handler: @escaping @Sendable ([String: String]) -> Void) {
        handlers.withLock { $0[option, default: []].append(handler) }
    }

    func fire(_ option: String, _ fields: [String: String]) {
        for handler in handlers.withLock({ $0[option] ?? [] }) { handler(fields) }
    }
}

/// Events, sent to the build as `emit` notifications.
nonisolated struct RemoteEmitter: EventEmitter {
    let connection: RPCConnection
    func emit(_ event: BuildEvent) { connection.notify("emit", event) }
}

/// The program's log lines, sent to the build as `log` notifications.
nonisolated struct RemoteLogHandler: LogHandler {
    let connection: RPCConnection
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String,
             function: String, line: UInt) {
        connection.notify("log", LogLine(level: level.rawValue, message: message.description))
    }
}
