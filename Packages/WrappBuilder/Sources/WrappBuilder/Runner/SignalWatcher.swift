//
//  SignalWatcher.swift
//  WrappBuilder
//
//  Watches for a step's signals while it runs (decision 19 of the builders
//  plan; docs/wrappfile.md#signals): looks at each watch once a second, and
//  hears the program's output and exit from whoever runs it.

import CoreGraphics
import Foundation
import Logging
import ProcessKit
import Synchronization
import WrappLogging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Signals")

/// Watches a set of signals while a step runs, telling `onFire` each time
/// one fires, with its fields. Watches about the program start once it's
/// known (`program(_:)`).
public nonisolated final class SignalWatcher: Sendable {
    let signals: [PlannedSignal]
    /// A watch's path, in full form or on this Mac, as a file.
    let resolve: @Sendable (String) -> URL?
    /// A module's watch, from its executor.
    let moduleWatch: @Sendable (String, String, String?) -> (any WatchProbe)?
    let onFire: @Sendable (String, [String: String]) -> Void

    private struct State {
        var program: WatchedProgram?
        var output: [String] = []
        var exit: Int32?
        var started = false
        var stopped = false
        /// Each signal's watches' state, by signal name.
        var watches: [String: [WatchState]] = [:]
    }

    /// What a watch has seen: for `--all`, whether it has fired since the
    /// signal last did, and its fields.
    struct WatchState {
        var fired: [String: String]?
        var probe: (any WatchProbe)?
        var logOffset: UInt64?
        var size: UInt64?
        var exists = false
        var present = false
        var exitSeen = false
    }

    private let state: Mutex<State>
    /// Held for a whole look, so two never interleave (the polling thread's
    /// and an exit's or the stop's), while `state` is held only to read and
    /// write it: what's told the watcher meanwhile never waits on a look's
    /// walk of a folder.
    private let looking = Mutex(())

    public init(signals: [PlannedSignal], resolve: @escaping @Sendable (String) -> URL?,
                moduleWatch: @escaping @Sendable (String, String, String?) -> (any WatchProbe)? = { _, _, _ in nil },
                onFire: @escaping @Sendable (String, [String: String]) -> Void) {
        self.signals = signals
        self.resolve = resolve
        self.moduleWatch = moduleWatch
        self.onFire = onFire
        var initial = State()
        for signal in signals {
            initial.watches[signal.name] = signal.watches.map { watch in
                var watchState = WatchState()
                if case .module(let id, let name, let value) = watch { watchState.probe = moduleWatch(id, name, value) }
                return watchState
            }
        }
        state = Mutex(initial)
    }

    /// Look once a second until `stop`.
    public func start() {
        guard !signals.isEmpty else { return }
        let first = state.withLock { state -> Bool in
            defer { state.started = true }
            return !state.started
        }
        guard first else { return }
        let build = LogContext.build
        Thread.detachNewThread { [self] in
            LogContext.$build.withValue(build) {
                while !state.withLock({ $0.stopped }) {
                    poll()
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }

    public func stop() {
        // A last look, so a line written just before the end still counts;
        // then none, so no signal fires once the step's done.
        poll()
        looking.withLock { _ in state.withLock { $0.stopped = true } }
    }

    /// The program the signals are about, once it's known.
    public func program(_ program: WatchedProgram) {
        state.withLock { $0.program = program }
    }

    /// A line the program wrote.
    public func output(_ line: String) {
        state.withLock { $0.output.append(line) }
    }

    /// The program ended with `code`.
    public func exited(_ code: Int32) {
        state.withLock { $0.exit = code }
        poll()
    }

    /// One look at every watch.
    func poll() {
        looking.withLock { _ in lookOnce() }
    }

    private func lookOnce() {
        let (program, lines, exit, stopped) = state.withLock { state -> (WatchedProgram?, [String], Int32?, Bool) in
            defer { state.output = [] }
            return (state.program, state.output, state.exit, state.stopped)
        }
        guard !stopped else { return }
        let processes = signals.contains { $0.watches.contains { if case .process = $0 { return true }; return false } }
            ? ProcessList.recent(maxAge: .seconds(1)) : nil
        for signal in signals {
            var fires: [[String: String]] = []
            guard var watches = state.withLock({ $0.watches[signal.name] }) else { continue }
            for (index, watch) in signal.watches.enumerated() {
                if let fields = Self.look(watch, state: &watches[index], program: program, lines: lines, exit: exit,
                                          processes: processes, resolve: resolve) {
                    watches[index].fired = fields
                    if signal.combine == .any { fires.append(fields) }
                }
            }
            if signal.combine == .all, watches.allSatisfy({ $0.fired != nil }) {
                fires.append(watches.reduce(into: [:]) { all, watch in all.merge(watch.fired ?? [:]) { $1 } })
                for index in watches.indices { watches[index].fired = nil }
            }
            if signal.combine == .any { for index in watches.indices { watches[index].fired = nil } }
            let latest = watches
            state.withLock { $0.watches[signal.name] = latest }
            for fields in fires { onFire(signal.name, fields) }
        }
    }

    /// Whether `watch` fires on this look, with its fields.
    static func look(_ watch: PlannedWatch, state: inout WatchState, program: WatchedProgram?, lines: [String], exit: Int32?,
                     processes: ProcessList?, resolve: (String) -> URL?) -> [String: String]? {
        // A path the program gives (`${program.log}`) is one on this Mac;
        // any other, a place in the tree, in full form.
        func file(_ path: String) -> URL? {
            guard path.contains("${program.") else { return resolve(path) }
            return program?.fill(path).map { URL(fileURLWithPath: $0) }
        }
        switch watch {
        case .log(let path, let pattern):
            guard let url = file(path) else { return nil }
            let (newLines, offset) = Self.newLines(of: url, from: state.logOffset)
            state.logOffset = offset
            return newLines.lazy.compactMap { Self.match($0, pattern) }.first
        case .output(let pattern):
            return lines.lazy.compactMap { Self.match($0, pattern) }.first
        case .file(let path):
            guard let url = file(path) else { return nil }
            let exists = FileManager.default.fileExists(atPath: url.path)
            defer { state.exists = exists }
            return exists && !state.exists ? ["path": url.path] : nil
        case .grows(let path):
            guard let url = file(path) else { return nil }
            let size = DirectorySize.of(url)
            defer { state.size = size }
            guard let before = state.size else { return nil }
            return size != before ? ["size": String(size)] : nil
        case .process(let name):
            let present = processes?.entries.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? false
            defer { state.present = present }
            return present && !state.present ? [:] : nil
        case .processHasWindow(let name):
            let present = Self.windowOnScreen(named: name, processes: processes ?? ProcessList.recent(maxAge: .seconds(1)))
            defer { state.present = present }
            return present && !state.present ? [:] : nil
        case .exits(let code):
            guard let exit, !state.exitSeen else { return nil }
            state.exitSeen = true
            return code.map { $0 == exit } ?? true ? ["code": String(exit)] : nil
        case .module:
            return state.probe?.poll()
        }
    }

    /// A line's fields if it has `pattern`: a `--matches`'s named groups.
    static func match(_ line: String, _ pattern: LinePattern) -> [String: String]? {
        switch pattern {
        case .contains(let text):
            return line.contains(text) ? [:] : nil
        case .matches(let expression):
            guard let regex = try? NSRegularExpression(pattern: expression),
                  let found = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            var fields: [String: String] = [:]
            for name in PlannedWatch.groupNames(in: expression) {
                if let range = Range(found.range(withName: name), in: line) { fields[name] = String(line[range]) }
            }
            return fields
        }
    }

    /// The lines added to `url` since `offset` (nil: none yet, so start at
    /// its end, as a log's lines from before the step aren't the step's).
    static func newLines(of url: URL, from offset: UInt64?) -> (lines: [String], offset: UInt64?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard let offset else { return ([], end) }
        guard end > offset else { return ([], end < offset ? 0 : offset) }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return (text.split(whereSeparator: \.isNewline).map(String.init), end)
    }

    /// Whether a Wine program, or one called `name`, has a window on screen.
    static func windowOnScreen(named name: String?, processes: ProcessList?) -> Bool {
        let candidates = (processes?.entries ?? []).filter { entry in
            name.map { entry.name.caseInsensitiveCompare($0) == .orderedSame } ?? entry.isWine
        }
        let pids = Set(candidates.map(\.pid))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Width"] ?? 0) > 1 && (bounds["Height"] ?? 0) > 1
        }
    }
}

/// A folder's size, in bytes, for `--grows`.
nonisolated enum DirectorySize {
    static func of(_ url: URL) -> UInt64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// A build's `EMIT --on` listeners, from the line each is reached to the end
/// of the build or its `EMIT --off`.
nonisolated final class Listeners: Sendable {
    struct Listener: Sendable {
        let name: String
        let signal: String
        let text: String
        let origin: String
    }

    private let listening = Mutex<[Listener]>([])

    var all: [Listener] { listening.withLock { $0 } }

    /// `emit`, reached: a listener added or stopped. False for a plain one.
    func reach(_ emit: PlannedEmit) throws -> Bool {
        if let name = emit.listener, let signal = emit.on {
            try listening.withLock { listening in
                guard !listening.contains(where: { $0.name == name }) else {
                    throw StepFailure.recipe("\(emit.origin): a listener called \(name) is listening already (give one --name)")
                }
                listening.append(Listener(name: name, signal: signal, text: emit.text, origin: emit.origin))
            }
            return true
        }
        if let off = emit.off {
            try listening.withLock { listening in
                guard listening.contains(where: { $0.name == off }) else {
                    throw StepFailure.recipe("\(emit.origin): EMIT --off=\(off), but no listener of that name is listening")
                }
                listening.removeAll { $0.name == off }
            }
            return true
        }
        return false
    }
}

/// One step's signals while it runs: those its `--alive`, `--done` and
/// `--asks` name, and the build's listeners', each listener emitting at
/// most once a second, the last value winning.
nonisolated final class StepSignals: Sendable {
    let step: PlannedStep
    let listeners: [Listeners.Listener]
    let emitter: any EventEmitter
    private let handlers = Mutex<[String: [@Sendable ([String: String]) -> Void]]>([:])
    private let program = Mutex<WatchedProgram?>(nil)
    private let coalesced = Mutex<[String: (last: ContinuousClock.Instant, pending: String?)]>([:])
    private let watcher = Mutex<SignalWatcher?>(nil)

    init(step: PlannedStep, plan: BuildPlan, listeners: [Listeners.Listener], emitter: any EventEmitter,
         resolve: @escaping @Sendable (String) -> URL?, moduleWatch: @escaping @Sendable (String, String, String?) -> (any WatchProbe)?) {
        self.step = step
        self.listeners = listeners
        self.emitter = emitter
        let names = Set(InstructionSpec.signalOptions.compactMap { step.option($0) } + listeners.map(\.signal))
        let signals = names.sorted().compactMap { plan.signals[$0] }
        guard !signals.isEmpty else { return }
        watcher.withLock { $0 = SignalWatcher(signals: signals, resolve: resolve, moduleWatch: moduleWatch) { [weak self] name, fields in
            self?.fired(name, fields)
        } }
    }

    func start() { watcher.withLock { $0 }?.start() }

    func watch(program: WatchedProgram) {
        self.program.withLock { $0 = program }
        watcher.withLock { $0 }?.program(program)
    }

    func programWrote(_ line: String) { watcher.withLock { $0 }?.output(line) }
    func programExited(_ code: Int32) { watcher.withLock { $0 }?.exited(code) }

    func onSignal(_ option: String, _ handler: @escaping @Sendable ([String: String]) -> Void) {
        handlers.withLock { $0[option, default: []].append(handler) }
    }

    /// The step has ended: the watcher stopped, and each listener's last
    /// value emitted.
    func finish() {
        watcher.withLock { $0 }?.stop()
        let pending = coalesced.withLock { all in all.compactMapValues(\.pending).sorted { $0.key < $1.key } }
        for (_, text) in pending { emitter.emit(.emitted(text)) }
    }

    private func fired(_ name: String, _ fields: [String: String]) {
        for option in InstructionSpec.signalOptions where step.option(option) == name {
            for handler in handlers.withLock({ $0[option] ?? [] }) { handler(fields) }
        }
        let program = program.withLock { $0 }
        for listener in listeners where listener.signal == name {
            var text = listener.text
            for (field, value) in fields { text = text.replacingOccurrences(of: "${signal.\(field)}", with: value) }
            if text.contains("${program.") { guard let filled = program?.fill(text) else { continue }; text = filled }
            let now = ContinuousClock.now
            let emitNow = coalesced.withLock { all -> Bool in
                if let last = all[listener.name]?.last, now - last < .seconds(1) {
                    all[listener.name]?.pending = text
                    return false
                }
                all[listener.name] = (now, nil)
                return true
            }
            if emitNow { emitter.emit(.emitted(text)) }
        }
    }
}
