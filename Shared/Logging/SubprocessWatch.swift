//
//  SubprocessWatch.swift
//  Shared
//
//  The start, end and silences of one subprocess, logged so a reader can
//  see what ran, for how long, and how it ended — without reading its
//  output. A Wine installer that hangs prints nothing, and a killed one
//  reports a signal as an exit code; this is what makes both visible.

import Foundation
import Logging

nonisolated final class SubprocessWatch: @unchecked Sendable {

    /// How a watched process ended.
    enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)

        var succeeded: Bool { self == .exited(0) }
    }

    let name: String
    private let logger: Logging.Logger
    private let heartbeat: TimeInterval
    private let lock = NSLock()
    private var startTime = Date()
    private var lastOutput = Date()
    private var lineCount = 0
    private var pid: Int32 = 0
    private var timer: DispatchSourceTimer?

    /// - Parameters:
    ///   - name: What to call the process in the log, e.g. `wine setup.exe`.
    ///   - heartbeat: Log a "still running" line after this long without output.
    init(name: String, logger: Logging.Logger, heartbeat: TimeInterval = 30) {
        self.name = name
        self.logger = logger
        self.heartbeat = heartbeat
    }

    /// Log the start and begin the heartbeat. `detail` is usually the
    /// command line.
    func started(pid: Int32, detail: String? = nil) {
        lock.withLock {
            self.pid = pid
            startTime = Date()
            lastOutput = startTime
        }
        if let detail {
            logger.notice("▶ \(name) started (pid \(pid)): \(detail)", metadata: metadata(pid))
        } else {
            logger.notice("▶ \(name) started (pid \(pid))", metadata: metadata(pid))
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + heartbeat, repeating: heartbeat)
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    /// Count a line of output; pass as (or call from) the line logger's `onLine`.
    func sawLine() {
        lock.withLock {
            lineCount += 1
            lastOutput = Date()
        }
    }

    /// Log how the process ended and stop the heartbeat.
    @discardableResult
    func finished(_ process: Process, note: String? = nil) -> Outcome {
        let outcome: Outcome = process.terminationReason == .uncaughtSignal
            ? .signalled(process.terminationStatus)
            : .exited(process.terminationStatus)
        finished(outcome, note: note)
        return outcome
    }

    func finished(_ outcome: Outcome, note: String? = nil) {
        let (elapsed, lines, pid) = lock.withLock { () -> (TimeInterval, Int, Int32) in
            timer?.cancel()
            timer = nil
            return (Date().timeIntervalSince(startTime), lineCount, self.pid)
        }
        let summary = "after \(Self.duration(elapsed)), \(lines) line\(lines == 1 ? "" : "s") of output"
        let suffix = note.map { " — \($0)" } ?? ""
        switch outcome {
        case .exited(0):
            logger.notice("■ \(name) (pid \(pid)) exited 0 \(summary)\(suffix)", metadata: metadata(pid))
        case .exited(let code):
            logger.error("■ \(name) (pid \(pid)) exited \(code) \(summary)\(suffix)", metadata: metadata(pid))
        case .signalled(let signal):
            logger.error("■ \(name) (pid \(pid)) was killed by \(Self.signalName(signal)) \(summary)\(suffix)", metadata: metadata(pid))
        }
    }

    private func tick() {
        let (elapsed, quiet, lines, pid) = lock.withLock {
            (Date().timeIntervalSince(startTime), Date().timeIntervalSince(lastOutput), lineCount, self.pid)
        }
        guard quiet >= heartbeat - 0.5 else { return }
        logger.notice("… \(name) (pid \(pid)) still running after \(Self.duration(elapsed)); no output for \(Self.duration(quiet)) (\(lines) lines so far)",
                      metadata: metadata(pid))
    }

    private func metadata(_ pid: Int32) -> Logging.Logger.Metadata {
        ["pid": "\(pid)", "program": "\(name)"]
    }

    /// `17.1s`, `4m 05s`.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%dm %02ds", whole / 60, whole % 60)
    }

    /// `SIGKILL (9)`.
    static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
            SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE",
            SIGKILL: "SIGKILL", SIGSEGV: "SIGSEGV", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM",
            SIGTERM: "SIGTERM",
        ]
        return "\(names[signal] ?? "signal") (\(signal))"
    }
}
