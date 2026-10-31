//
//  ProcessUtilities.swift
//  SecondChance
//
//  Running a program without freezing the window: `Process.output(of:_:)`
//  waits for it through `Blocking.run` (Shared/Blocking.swift).

import Foundation
import SecondChanceKit

/// What a finished subprocess said and how it ended.
nonisolated struct ProcessOutput: Sendable {
    let status: Int32
    let output: String
    let errorOutput: String

    var succeeded: Bool { status == 0 }
}

extension Process {
    /// Run a program to completion on a background thread: its exit status,
    /// and what it wrote to stdout and stderr, both read as it runs so a
    /// chatty program can't fill a pipe and stall. Not for Wine, which must
    /// start through `runWithoutCrashHandler()`.
    nonisolated static func output(
        of executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessOutput {
        try await Blocking.run {
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
            try process.run()

            // stderr on another thread while this one reads stdout: either
            // could fill its pipe first.
            let errorRead = DispatchGroup()
            nonisolated(unsafe) var errorData = Data()
            errorRead.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                errorRead.leave()
            }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            errorRead.wait()
            process.waitUntilExit()
            return ProcessOutput(
                status: process.terminationStatus,
                output: String(decoding: outputData, as: UTF8.self),
                errorOutput: String(decoding: errorData, as: UTF8.self)
            )
        }
    }
}
