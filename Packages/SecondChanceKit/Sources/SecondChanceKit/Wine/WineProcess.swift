//
//  WineProcess.swift
//  Shared
//
//  The one place a Process is built for Wine. Every Wine, wineserver and
//  winetricks process starts here, so each:
//  - starts with `runWithoutCrashHandler()`, so it doesn't inherit Sentry's
//    exception ports (docs/failure-reports.md#child-processes)
//  - gets stdin from /dev/null, unless it's run in the terminal
//  - has its output logged line by line, each line carrying its pid
//  - is never waited on for EOF for more than a few seconds, since Wine's
//    background services inherit its pipes and hold them open.

import Foundation
import Logging

/// Second Chance's lines about the Wine programs it runs. A fixed label:
/// this package is linked by three targets with three different subsystems,
/// so this file cannot pick one — a stable `.Shared` leaf still matches
/// `BEGINSWITH 'au.gare.callum.second-chance'`.
private nonisolated let launcherLogger = Logger(label: "au.gare.callum.second-chance.Shared.WineProcess")

extension Logger {
    /// What Wine and the Windows programs it runs print, as its own category
    /// so it can be told apart from Second Chance's lines about running it.
    nonisolated public static let wineOutput = Logger(label: "au.gare.callum.second-chance.Shared.Wine")
}

/// Where a Wine program's output goes.
nonisolated public enum WineOutput: Sendable {
    /// Into the log, line by line; `onLine` sees each line first.
    case log(Logger = .wineOutput, onLine: (@Sendable (String) -> Void)? = nil)
    /// Our own stdin, stdout and stderr: the `wine` pass-through and the debug
    /// commands.
    case terminal
    case discard
}

/// What a timeout, or cancelling the task, stops.
nonisolated public enum OnTimeout: Sendable {
    /// The prefix's whole Wine session (`wineserver -k`): a program stuck on
    /// another Windows program is only freed by ending both.
    case stopSession
    /// Just the program: what a check does, so it doesn't end the very
    /// session it is checking on.
    case stopProgram
}

nonisolated extension Wine {
    /// Run `command` and wait for it, logging a `▶` line when it starts, a
    /// `…` heartbeat whenever it has been quiet for 30 s, and a `■` line
    /// saying how it ended (`SubprocessWatch`).
    ///
    /// Throws `WineError.executionFailed` on a non-zero exit,
    /// `.terminatedBySignal` when it was killed, `.timedOut` when `timeout`
    /// passes first, `.stalled` when `watchdog` says it has stopped getting
    /// anywhere, and `.noDisplay` when it printed Wine's `nodrv_CreateWindow`,
    /// whatever its exit code. A timeout, a stall and cancelling the task stop
    /// what `onTimeout` says.
    public func run(
        _ command: WineCommand,
        environment extra: [String: String] = [:],
        timeout: TimeInterval? = nil,
        onTimeout: OnTimeout = .stopSession,
        watchdog: WineWatchdog? = nil,
        output: WineOutput = .log()
    ) async throws {
        launcherLogger.debug("To re-run by hand:\n\(command.commandLine(in: self))")
        // In the terminal, its own output is what someone is there to read.
        let quiet: Bool = if case .terminal = output { true } else { false }
        let watch = SubprocessWatch(name: command.displayName, logger: launcherLogger, level: quiet ? .debug : nil)
        let noDisplay = NoDisplaySignal()
        let launched = try launch(command, environment: extra, output: output, watch: watch) { line in
            noDisplay.check(line)
            watchdog?.sawOutput()
        }
        let ending = await wait(for: launched, timeout: timeout, onTimeout: onTimeout, watchdog: watchdog, watch: watch)
        try finish(launched, ending: ending, timeout: timeout, noDisplay: noDisplay, watch: watch)
    }

    /// Run `command` and return what it printed, stdout and stderr together.
    ///
    /// Captured to a file, never a pipe: Wine's background services inherit
    /// a pipe and hold it open, so reading one to its end can wait for ever.
    /// Its `▶`/`■` lines are logged at `.debug`, for checks run every few
    /// seconds. Throws as `run` does, a captured `nodrv_CreateWindow` line
    /// included.
    public func output(
        of command: WineCommand,
        timeout: TimeInterval? = nil,
        onTimeout: OnTimeout = .stopProgram
    ) async throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-chance-wine-output-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let watch = SubprocessWatch(name: command.displayName, logger: launcherLogger, level: .debug)
        let launched = try launch(command, environment: [:], output: .discard, watch: watch, capturingTo: handle)
        let ending = await wait(for: launched, timeout: timeout, onTimeout: onTimeout, watchdog: nil, watch: watch)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let noDisplay = NoDisplaySignal()
        text.split(separator: "\n").forEach { noDisplay.check(String($0)) }
        try finish(launched, ending: ending, timeout: timeout, noDisplay: noDisplay, watch: watch)
        return text
    }

    /// Start `command` and return without waiting: the game, Steam, the desktop.
    public func start(
        _ command: WineCommand,
        environment extra: [String: String] = [:],
        output: WineOutput = .log()
    ) throws -> WineProcess {
        let launched = try launch(command, environment: extra, output: output, watch: nil)
        launcherLogger.debug("Started \(command.displayName) (pid \(launched.process.pid)): \(command.arguments.joined(separator: " "))")
        return launched.process
    }

    // MARK: - Launching

    private struct Launched {
        let process: WineProcess
        let name: String
        /// Left once per pipe, at its EOF.
        let eofs: DispatchGroup
        let pipes: [Pipe]
    }

    private func launch(
        _ command: WineCommand,
        environment extra: [String: String],
        output: WineOutput,
        watch: SubprocessWatch?,
        capturingTo capture: FileHandle? = nil,
        onLine extraOnLine: (@Sendable (String) -> Void)? = nil
    ) throws -> Launched {
        let executable = command.executable(in: self)
        if command.isBundled, !FileManager.default.fileExists(atPath: executable.path) {
            launcherLogger.error("Can't run \(command.displayName): there's no Wine at \(executable.path)")
            throw WineError.notBundled
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.processArguments
        process.environment = environment.merging(extra) { $1 }
        process.currentDirectoryURL = command.directory
        let wineProcess = WineProcess(process)

        var pipes: [Pipe] = []
        switch output {
        case .terminal:
            // Wired explicitly: Foundation nominally inherits them, but not
            // reliably for a GUI app's binary run from a terminal.
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        case .discard:
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = capture ?? FileHandle.nullDevice
            process.standardError = capture ?? FileHandle.nullDevice
        case .log:
            process.standardInput = FileHandle.nullDevice
            pipes = [Pipe(), Pipe()]
            process.standardOutput = pipes[0]
            process.standardError = pipes[1]
        }

        do {
            try process.runWithoutCrashHandler()
        } catch {
            launcherLogger.error("Could not start \(command.displayName): \(error)")
            throw error
        }
        watch?.started(pid: process.processIdentifier, detail: command.arguments.joined(separator: " "))

        // Attached once the pid is known, so every line carries it; the pipes
        // hold anything written in the meantime.
        let eofs = DispatchGroup()
        if case .log(let logger, let onLine) = output {
            let metadata: Logger.Metadata = ["pid": "\(process.processIdentifier)", "program": "\(command.displayName)"]
            let seeLine: @Sendable (String) -> Void = { line in
                watch?.sawLine()
                extraOnLine?(line)
                onLine?(line)
            }
            for (pipe, level) in zip(pipes, [Logger.Level.notice, .warning]) {
                eofs.enter()
                ProcessLineLogger.attach(to: pipe, logger: logger, level: level, metadata: metadata,
                                         onLine: seeLine, onEOF: { eofs.leave() })
            }
        }
        return Launched(process: wineProcess, name: command.displayName, eofs: eofs, pipes: pipes)
    }

    // MARK: - Waiting

    enum WaitEnding: Equatable {
        case exited
        case timedOut
        case stalled(quietFor: TimeInterval)
    }

    /// Wait for it to exit, its timeout or its watchdog, stopping what
    /// `onTimeout` says if it doesn't exit; then let its last lines through.
    private func wait(
        for launched: Launched,
        timeout: TimeInterval?,
        onTimeout: OnTimeout,
        watchdog: WineWatchdog?,
        watch: SubprocessWatch
    ) async -> WaitEnding {
        let process = launched.process
        let name = launched.name
        // A check stopped short is routine; an installer stopped short isn't.
        let level: Logger.Level = onTimeout == .stopSession ? .error : .debug
        let stop: @Sendable () -> Void = {
            if onTimeout == .stopSession { self.server.stopNow() }
            process.terminate()
        }
        // The wait is on a queue of its own; what it logs is still the build's.
        let build = LogContext.build
        let ending: WaitEnding = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { LogContext.$build.withValue(build) {
                    let ending = Self.wait(for: process.exited, timeout: timeout, watchdog: watchdog)
                    let what = onTimeout == .stopSession ? "its Wine session" : "it"
                    switch ending {
                    case .exited:
                        process.exited.signal()  // for any other waiter
                        continuation.resume(returning: ending)
                        return
                    case .timedOut:
                        launcherLogger.log(level: level, "\(name) did not finish within \(SubprocessWatch.duration(timeout ?? 0)) — stopping \(what)")
                    case .stalled(let quietFor):
                        launcherLogger.log(level: level, "\(name) showed no sign of progress for \(SubprocessWatch.duration(quietFor)) — stopping \(what)")
                    }
                    if onTimeout == .stopSession {
                        // What was still running, before it is killed: a hung
                        // installer is often waiting on another Windows process.
                        launcherLogger.warning("Wine processes when it was stopped:\n\(Self.wineProcessSnapshot())")
                    }
                    stop()
                    if !process.waitUntilExit(within: 10) {
                        process.kill()
                        _ = process.waitUntilExit(within: nil)
                    }
                    continuation.resume(returning: ending)
                } }
            }
        } onCancel: {
            launcherLogger.log(level: onTimeout == .stopSession ? .notice : .debug,
                               "Cancelled: stopping \(name)\(onTimeout == .stopSession ? " and its Wine session" : "")")
            stop()
        }

        // Let the last lines through, but don't wait long for EOF: Wine's
        // background services inherit the pipes and hold them open until the
        // wineserver exits, a few seconds after the last Windows process.
        if !launched.pipes.isEmpty {
            let eofs = launched.eofs
            _ = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: eofs.wait(timeout: .now() + 5))
                }
            }
            launched.pipes.forEach { $0.fileHandleForReading.readabilityHandler = nil }
        }
        return ending
    }

    /// Log how it ended, and throw unless it did its job.
    private func finish(_ launched: Launched, ending: WaitEnding, timeout: TimeInterval?,
                        noDisplay: NoDisplaySignal, watch: SubprocessWatch) throws {
        let note: String? = switch ending {
        case .timedOut: "timed out"
        case .stalled: "stalled"
        case .exited: Task.isCancelled ? "cancelled" : nil
        }
        let outcome = watch.finished(launched.process.process, note: note)
        try Task.checkCancellation()
        switch ending {
        case .timedOut: throw WineError.timedOut(seconds: timeout ?? 0)
        case .stalled(let quietFor): throw WineError.stalled(quietFor: quietFor)
        case .exited: break
        }
        // Whatever the exit code: a program that couldn't open a window has
        // not done its job, and AutoIt in that state exits 0 without running
        // its script.
        if noDisplay.seen {
            throw WineError.noDisplay
        }
        switch outcome {
        case .exited(0):
            return
        case .exited(let code):
            throw WineError.executionFailed(exitCode: code)
        case .signalled(let signal):
            throw WineError.terminatedBySignal(signal)
        }
    }

    /// Wait for the program to exit, for `timeout` to pass, or for `watchdog`
    /// to say it has stalled, asking the watchdog every `tick` seconds. Time
    /// the watchdog says is spent waiting on the person doesn't count towards
    /// the timeout.
    static func wait(for exited: DispatchSemaphore, timeout: TimeInterval?, watchdog: WineWatchdog?,
                     tick: TimeInterval = 5) -> WaitEnding {
        guard let watchdog else {
            let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
            return exited.wait(timeout: deadline) == .success ? .exited : .timedOut
        }
        var remaining = timeout
        while true {
            let slice = remaining.map { min(tick, max(0, $0)) } ?? tick
            if exited.wait(timeout: .now() + slice) == .success { return .exited }
            switch watchdog.check() {
            case .carryOn:
                remaining = remaining.map { $0 - slice }
            case .waitingOnPerson:
                break
            case .stalled(let quietFor):
                return .stalled(quietFor: quietFor)
            }
            if let left = remaining, left <= 0 { return .timedOut }
        }
    }

    /// A line for every Wine process: pid, parent, CPU, how long it has run
    /// and its command.
    static func wineProcessSnapshot() -> String {
        guard let processes = ProcessList.current() else { return "(couldn't run ps)" }
        let lines = processes.wine.map { process in
            "  \(process.pid) \(process.parent) \(String(format: "%.1f", process.cpuPercent))% "
                + "\(SubprocessWatch.duration(process.elapsedSeconds)) \(process.command.prefix(200))"
        }
        return (["  PID PARENT CPU RUNNING COMMAND"] + lines).joined(separator: "\n")
    }
}

/// A Wine program started with `Wine.start`, or being waited for by `run`.
///
/// `@unchecked Sendable`: it wraps a `Process`, which isn't `Sendable`, and
/// touches it only through calls that are safe from any thread.
nonisolated public final class WineProcess: @unchecked Sendable {
    /// For code that watches a `Process`, such as `GameMonitor`.
    public let process: Process
    /// Signalled when it exits, and again by each waiter it lets through.
    fileprivate let exited = DispatchSemaphore(value: 0)

    fileprivate init(_ process: Process) {
        self.process = process
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// SIGTERM.
    public func terminate() { process.terminate() }

    /// SIGKILL.
    public func kill() { Darwin.kill(process.processIdentifier, SIGKILL) }

    /// Wait for it to exit: how it ended, or nil if `timeout` passed first.
    func waitUntilExit(timeout: TimeInterval?) async -> SubprocessWatch.Outcome? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.waitUntilExit(within: timeout) ? self.outcome : nil)
            }
        }
    }

    /// Blocks. True once it has exited.
    func waitUntilExit(within timeout: TimeInterval?) -> Bool {
        guard exited.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .success else { return false }
        exited.signal()
        return true
    }

    private var outcome: SubprocessWatch.Outcome {
        process.terminationReason == .uncaughtSignal
            ? .signalled(process.terminationStatus)
            : .exited(process.terminationStatus)
    }
}

/// Watches a Wine program's output for `nodrv_CreateWindow`, the line Wine
/// prints when a program tries to open a window without a working desktop.
nonisolated final class NoDisplaySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    var seen: Bool { lock.withLock { flagged } }

    func check(_ line: String) {
        guard line.contains("nodrv_CreateWindow") else { return }
        lock.withLock { flagged = true }
    }
}
