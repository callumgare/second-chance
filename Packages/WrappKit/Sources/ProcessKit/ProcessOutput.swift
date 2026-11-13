//
//  ProcessOutput.swift
//  ProcessKit
//
//  Running a program without freezing the window: `Process.output(of:_:)`
//  reads its output as it comes and answers when it exits, holding no
//  thread while it runs.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.ProcessOutput")

/// What a finished subprocess said and how it ended.
nonisolated public struct ProcessOutput: Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public init(status: Int32, output: String, errorOutput: String) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }

    public var succeeded: Bool { status == 0 }
}

extension Process {
    /// Run a program to completion: its exit status,
    /// and what it wrote to stdout and stderr, both read as it runs so a
    /// chatty program can't fill a pipe and stall. Not for Wine, which must
    /// start through `runWithoutCrashHandler()`.
    ///
    /// Cancelling the task stops the program (SIGTERM) and throws
    /// `CancellationError`, so a cancelled build doesn't wait for a copy or
    /// an `hdiutil` to finish first.
    nonisolated public static func output(
        of executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        // Nothing to answer a question with: say no rather than wait.
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                let reading = PipeReading(process: process, pipes: [outputPipe, errorPipe], continuation: continuation)
                reading.start()
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return output
    }
}

/// Reads a running program's stdout and stderr as they're written, so a
/// chatty program can't fill a pipe and stall, and answers once the program
/// has exited, with what was left in the pipes read then. It never waits for
/// a pipe's end: a daemon the program starts inherits its pipes and can hold
/// them open long after it has gone, as actool's `ibtoold` does on a Mac
/// where it isn't running already.
///
/// Everything happens on one serial queue, so the reads, the exit and the
/// answer never race and the output stays in order.
private nonisolated final class PipeReading: @unchecked Sendable {
    private let process: Process
    private let handles: [FileHandle]
    private let fds: [Int32]
    /// Whether each pipe may still have something to read; false once it has ended.
    private var open: [Bool]
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.ProcessOutput", qos: .userInitiated)
    private var sources: [DispatchSourceRead] = []
    private var data: [Data]
    private var continuation: CheckedContinuation<ProcessOutput, Error>?

    init(process: Process, pipes: [Pipe], continuation: CheckedContinuation<ProcessOutput, Error>) {
        self.process = process
        self.handles = pipes.map(\.fileHandleForReading)
        self.fds = handles.map(\.fileDescriptor)
        self.open = Array(repeating: true, count: pipes.count)
        self.data = Array(repeating: Data(), count: pipes.count)
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            for (index, handle) in handles.enumerated() {
                let fd = fds[index]
                // Reads never block: a source says when there's something, and the drain at exit takes what's left.
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [self] in
                    drain(index)
                    if !open[index] { source.cancel() }
                }
                // Closed only once its source is done with it.
                source.setCancelHandler {
                    do { try handle.close() } catch { logger.debug("Couldn't close a program's pipe: \(error)") }
                }
                sources.append(source)
                source.resume()
            }
            process.terminationHandler = { [self] _ in queue.async { self.finish() } }
            do { try process.run() } catch {
                sources.forEach { $0.cancel() }
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    /// Reads what pipe `index` has now, marking it ended at its end or when it can't be read.
    private func drain(_ index: Int) {
        guard open[index] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fds[index], &buffer, buffer.count)
            if count > 0 { data[index].append(buffer, count: count); continue }
            if count < 0 && errno == EINTR { continue }
            if count == 0 || errno != EAGAIN { open[index] = false }
            return
        }
    }

    /// The program has exited: everything it wrote is in the pipes, so take it and answer.
    private func finish() {
        guard let continuation else { return }
        for index in handles.indices { drain(index) }
        sources.forEach { $0.cancel() }
        self.continuation = nil
        continuation.resume(returning: ProcessOutput(
            status: process.terminationStatus,
            output: String(decoding: data[0], as: UTF8.self),
            errorOutput: String(decoding: data[1], as: UTF8.self)
        ))
    }
}
