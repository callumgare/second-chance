//
//  TaggedProcess.swift
//  Shared
//
//  A thin wrapper around Foundation's `Process` that captures stdout and
//  stderr and forwards each line to a swift-log logger via
//  `ProcessLineLogger`.
//
//  Usage:
//    let process = TaggedProcess(logger: Logger(label: "au.gare.callum.second-chance.SecondChance.wine"))
//    process.executableURL = wineURL
//    process.arguments = [...]
//    try process.run()
//    process.waitUntilExit()
//
//  For processes whose pipes you build yourself (see
//  `WineEnvironment.runWindowsExecutableWithStart`), use
//  `ProcessLineLogger.attach(to:logger:level:)` directly instead.

import Foundation
import Logging

nonisolated final class TaggedProcess: @unchecked Sendable {

    // Delegate to a real Process for all configuration.
    /// Escape hatch for callers that need the underlying Process (e.g. to
    /// set properties this wrapper doesn't forward).
    let process = Process()
    private let logger: Logging.Logger

    // Expose the most-used Process properties directly
    var executableURL: URL? {
        get { process.executableURL }
        set { process.executableURL = newValue }
    }
    var arguments: [String]? {
        get { process.arguments }
        set { process.arguments = newValue }
    }
    var environment: [String: String]? {
        get { process.environment }
        set { process.environment = newValue }
    }
    var currentDirectoryURL: URL? {
        get { process.currentDirectoryURL }
        set { process.currentDirectoryURL = newValue }
    }
    var standardInput: Any? {
        get { process.standardInput }
        set { process.standardInput = newValue }
    }
    var terminationStatus: Int32 { process.terminationStatus }
    var terminationReason: Process.TerminationReason { process.terminationReason }
    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    init(logger: Logging.Logger) {
        self.logger = logger
    }

    // MARK: - Run

    /// Run the process, capturing stdout and stderr line-by-line and
    /// forwarding each line to the logger (stdout → `.notice`,
    /// stderr → `.error`). Returns immediately after starting the process
    /// (non-blocking); call `waitUntilExit()` to block until it finishes.
    func run() throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        ProcessLineLogger.attach(to: stdoutPipe, logger: logger, level: .notice)
        ProcessLineLogger.attach(to: stderrPipe, logger: logger, level: .error)

        try process.run()
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func terminate() {
        process.terminate()
    }

    func interrupt() {
        process.interrupt()
    }
}
