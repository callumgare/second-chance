//
//  TaggedProcess.swift
//  SecondChance
//
//  A thin wrapper around Foundation's `Process` that captures stdout and stderr
//  from a subprocess and forwards each line to a `ContextualLogger`. This
//  ensures subprocess output (Wine, AutoIt, exiftool, ScummVM, etc.) is tagged
//  with the caller's step and source context at spawn time — the one moment
//  when the context is unambiguously known.
//
//  Usage:
//    let process = TaggedProcess(logger: logger.withSource("wine"))
//    process.executableURL = wineURL
//    process.arguments = [...]
//    try process.run()
//    process.waitUntilExit()

import Foundation

final class TaggedProcess: @unchecked Sendable {

    // Delegate to a real Process for all configuration
    let process = Process()
    private let logger: ContextualLogger

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
    var terminationStatus: Int32 { process.terminationStatus }
    var terminationReason: Process.TerminationReason { process.terminationReason }
    var isRunning: Bool { process.isRunning }

    init(logger: ContextualLogger) {
        self.logger = logger
    }

    // MARK: - Run

    /// Run the process, capturing stdout and stderr line-by-line and forwarding
    /// each line to the logger with this process's context. Returns immediately
    /// after starting the process (non-blocking); call `waitUntilExit()` to
    /// block until it finishes.
    func run() throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        setupLineReader(pipe: stdoutPipe, level: .info)
        setupLineReader(pipe: stderrPipe, level: .warning)

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

    // MARK: - Line reading

    private func setupLineReader(pipe: Pipe, level: LogLevel) {
        let capturedLogger = logger
        let fh = pipe.fileHandleForReading

        // Buffer for partial lines
        var buffer = Data()

        fh.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — flush any remaining buffer
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    capturedLogger.log(line.trimmingCharacters(in: .newlines), level: level)
                    buffer.removeAll()
                }
                handle.readabilityHandler = nil
                return
            }

            buffer.append(data)

            // Split on newlines, forwarding complete lines
            while let range = buffer.range(of: Data("\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.upperBound.advanced(by: -1))
                if let line = String(data: lineData, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .controlCharacters)
                    if !trimmed.isEmpty {
                        capturedLogger.log(trimmed, level: level)
                    }
                }
            }
        }
        fh.waitForDataInBackgroundAndNotify()
    }
}

// MARK: - ContextualLogger source convenience

extension ContextualLogger {
    /// Return a child logger with `source` set, for passing to `TaggedProcess`.
    func withSource(_ source: String) -> ContextualLogger {
        self.source(source)
    }
}
