//
//  ContextualLogger.swift
//  SecondChance
//
//  A logger that carries its own context (current install step, source tag) so
//  that each log line is self-describing. All entries are routed through
//  LogCorrelator.shared, which emits via print(). LogManager's stdout pipe tee
//  then fans that output out to the console and the log window identically.

import Foundation

/// Default sink for all `ContextualLogger` instances — routes through the
/// shared `LogCorrelator` so output is formatted consistently everywhere.
/// Defined as a free function so it can be used as a default parameter value.
let defaultLogSink: @Sendable (LogEntry) -> Void = { entry in
    Task { await LogCorrelator.shared.render(entry: entry) }
}

/// A single structured log entry produced by `ContextualLogger`.
struct LogEntry: Sendable {
    /// The install step this line belongs to, if known. `nil` for app-level logs.
    let step: InstallationState?

    /// The source of the line: a Swift module, a subprocess name ("wine",
    /// "exiftool", "autoit"), or `nil` for Second Chance's own code.
    let source: String?

    /// Severity.
    let level: LogLevel

    /// The human-readable message.
    let message: String

    /// When the entry was produced.
    let timestamp: Date
}

/// A logger that stamps every line with step and source context. Context is
/// bound via chaining (`logger.step(.installingGame).source("wine").log(...)`)
/// so the call site always knows the context at the point of emission.
///
/// `ContextualLogger` is a value type — chaining returns a new logger with more
/// context bound, leaving the original unchanged. It is `@unchecked Sendable`
/// because its only mutable reference is the `sink` closure, which is assumed to
/// be thread-safe (LogManager and LogCorrelator dispatch to their own queues).
struct ContextualLogger: @unchecked Sendable {
    let step: InstallationState?
    let source: String?
    let level: LogLevel
    let sink: @Sendable (LogEntry) -> Void

    /// Create a root logger. Most code obtains one via `ContextualLogger.root`
    /// or via an injected property on its service.
    init(
        step: InstallationState? = nil,
        source: String? = nil,
        level: LogLevel = .info,
        sink: @Sendable @escaping (LogEntry) -> Void = defaultLogSink
    ) {
        self.step = step
        self.source = source
        self.level = level
        self.sink = sink
    }

    /// A process-wide root logger. Equivalent to `ContextualLogger()`.
    static let root = ContextualLogger()

    // MARK: - Context binding (chainable)

    /// Return a new logger bound to a specific install step.
    func step(_ step: InstallationState) -> ContextualLogger {
        ContextualLogger(step: step, source: source, level: level, sink: sink)
    }

    /// Return a new logger bound to a source tag (e.g. "wine", "exiftool").
    func source(_ source: String) -> ContextualLogger {
        ContextualLogger(step: step, source: source, level: level, sink: sink)
    }

    /// Return a new logger with a different default level.
    func atLevel(_ level: LogLevel) -> ContextualLogger {
        ContextualLogger(step: step, source: source, level: level, sink: sink)
    }

    // MARK: - Emitting

    /// Log a message at the logger's default level.
    func log(_ message: String) {
        emit(message, level: level)
    }

    /// Log a message at a specific level, overriding the logger's default.
    func log(_ message: String, level: LogLevel) {
        emit(message, level: level)
    }

    /// Convenience: log at `.info`.
    func info(_ message: String) { emit(message, level: .info) }

    /// Convenience: log at `.warning`.
    func warning(_ message: String) { emit(message, level: .warning) }

    /// Convenience: log at `.error`.
    func error(_ message: String) { emit(message, level: .error) }

    private func emit(_ message: String, level: LogLevel) {
        sink(LogEntry(
            step: step,
            source: source,
            level: level,
            message: message,
            timestamp: Date()
        ))
    }
}

// MARK: - LogEntry rendering

extension LogEntry {
    /// Render the entry as a single human-readable line. The LogCorrelator
    /// (later phase) produces richer output (headers, indentation); this default
    /// formatting keeps the interim LogManager forward simple and readable.
    func formatted() -> String {
        var prefix = ""
        if let step = step {
            // Use displayText (public) rather than baseText (private).
            prefix += "[\(step.displayText)]"
        }
        if let source = source {
            prefix += prefix.isEmpty ? "[\(source)]" : " [\(source)]"
        }
        let levelMark: String
        switch level {
        case .info: levelMark = ""
        case .warning: levelMark = "⚠️ "
        case .error: levelMark = "❌ "
        }
        return prefix.isEmpty ? "\(levelMark)\(message)" : "\(prefix) \(levelMark)\(message)"
    }
}
