//
//  SecondChanceRunner.swift
//  SecondChanceTests
//
//  Launches Second Chance.app as a subprocess in non-interactive mode,
//  connects an AutomationClient to the bridge socket, and waits for the
//  process to exit.
//
//  Usage:
//    let runner = try await SecondChanceRunner.launch(disk1: ..., outputDir: ...)
//    let (exitCode, events) = try await runner.waitForCompletion(timeout: 600)
//    if let logData = runner.logData { Attachment.record(logData, named: "...") }

import Foundation
import Darwin
import Testing
@testable import SecondChance

final class SecondChanceRunner: @unchecked Sendable {

    // MARK: - Public interface

    let client: AutomationClient

    /// Wait for Second Chance to exit. Returns exit code and all events received.
    func waitForCompletion(timeout: TimeInterval = 600) async throws -> (exitCode: Int32, events: [AutomationMessage]) {
        // Collect events and wait for exit concurrently.
        async let events = client.collectAll()
        let exitCode = try await waitForExit(timeout: timeout)
        return (exitCode, await events)
    }

    /// Raw log output written by Second Chance (from SC_LOG_PATH). Non-nil after exit.
    var logData: Data? { try? Data(contentsOf: URL(fileURLWithPath: logPath)) }

    // MARK: - Launch

    static func launch(
        disk1: URL,
        disk2: URL? = nil,
        outputDir: URL,
        game: GameInfo,
        strictInstall: Bool = true
    ) async throws -> SecondChanceRunner {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-automation-\(UUID().uuidString).sock").path
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-log-\(UUID().uuidString).txt").path

        let appExecutable = TestPaths.repoRoot
            .appendingPathComponent("DerivedData/Build/Products/Debug/Second Chance.app/Contents/MacOS/Second Chance")

        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else {
            throw SecondChanceRunnerError.appNotFound(appExecutable.path)
        }

        // Inherit the parent environment so Wine, dyld, etc. resolve correctly.
        var env = ProcessInfo.processInfo.environment
        env["NON_INTERACTIVE"]       = "true"
        env["INSTALLATION_SOURCE"]   = "disk"
        env["DISK_1_PATH"]           = disk1.path
        env["OUTPUT_PATH"]           = outputDir.path
        env["STRICT_INSTALL"]        = strictInstall ? "true" : "false"
        env["SC_AUTOMATION_SOCKET"]  = socketPath
        env["SC_LOG_PATH"]           = logPath
        if let disk2 { env["DISK_2_PATH"] = disk2.path }

        let process = Process()
        process.executableURL = appExecutable
        process.environment = env

        // Launch the process — the socket is created in the app's init() shortly after.
        try process.run()

        // Poll until the socket file appears (created by the bridge on app start).
        let client = try await connectWithRetry(socketPath: socketPath, timeout: 15)

        return SecondChanceRunner(process: process, client: client, logPath: logPath, socketPath: socketPath)
    }

    // MARK: - Private

    private let process: Process
    private let logPath: String
    private let socketPath: String

    private init(process: Process, client: AutomationClient, logPath: String, socketPath: String) {
        self.process = process
        self.client = client
        self.logPath = logPath
        self.socketPath = socketPath
    }

    private func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                let pid = self.process.processIdentifier
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                // WIFEXITED = (status & 0x7f) == 0; WEXITSTATUS = (status >> 8) & 0xff
                return (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 1
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return -1  // timeout sentinel
            }
            let result = try await group.next()!
            group.cancelAll()
            if result == -1 {
                self.process.terminate()
                throw SecondChanceRunnerError.timeout(timeout)
            }
            return result
        }
    }

    private static func connectWithRetry(socketPath: String, timeout: TimeInterval) async throws -> AutomationClient {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = AutomationError.connectionTimeout(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                do { return try AutomationClient(socketPath: socketPath) } catch { lastError = error }
            }
            try await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
        }
        throw lastError
    }
}

// MARK: - Errors

enum SecondChanceRunnerError: Error, LocalizedError {
    case appNotFound(String)
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let p): "Second Chance.app executable not found at \(p)"
        case .timeout(let t):    "Second Chance.app did not exit within \(Int(t))s"
        }
    }
}
