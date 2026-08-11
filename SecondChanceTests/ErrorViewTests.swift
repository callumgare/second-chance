//
//  ErrorViewTests.swift
//  SecondChanceTests
//
//  Tests for ErrorView's "Show Logs" and "Save Logs" functionality.
//  Triggers an installation error by pointing at an empty directory,
//  then verifies the log window and log export behave correctly.

import Testing
import Foundation
import os
@testable import SecondChance

@Suite("ErrorView log actions", .serialized)
struct ErrorViewTests {

    // MARK: - Helpers

    /// Drive an install with an empty temp dir so GameDetector fails → error state.
    private func triggerInstallError() async throws -> InstallationViewModel {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-error-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-error-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        PreconfiguredPaths.disk1 = emptyDir
        PreconfiguredPaths.outputDir = outputDir
        defer { PreconfiguredPaths.clear() }

        let viewModel = await MainActor.run { InstallationViewModel() }

        let recorder = RecordingEventSubscriber()
        await recorder.subscribe(to: EventBus.app)
        defer { Task { await recorder.unsubscribe(from: EventBus.app) } }

        Task { await MainActor.run { Task { await viewModel.installFromDisk() } } }

        // Wait for either a failure event or timeout
        _ = await recorder.waitForCompletion(timeout: 30)

        return viewModel
    }

    // MARK: - Show Logs

    @Test("Show Logs opens log window and it contains installation log entries")
    func showLogsOpensWindow() async throws {
        // Collect from the shared instance — same object ErrorView's button uses.
        let collector = LineCollector()
        LogWindow.shared.onLine = { line in Task { await collector.add(line) } }
        defer { LogWindow.shared.onLine = nil; LogWindow.shared.stopStreaming() }

        _ = try await triggerInstallError()

        // Simulate the "Show Logs" button: showLogWindow starts streaming from processStartTime.
        await MainActor.run {
            LogWindow.shared.showLogWindow(title: "Test - Installation Log")
        }

        // Poll up to 10 s for lines to arrive.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await collector.lines.count > 0 { break }
            try await Task.sleep(for: .milliseconds(250))
        }

        await MainActor.run { LogWindow.shared.hideLogWindow() }

        let count = await collector.lines.count
        #expect(count > 0, "Log window received no lines after install error")
    }

    // MARK: - Save Logs

    @Test("Save Logs writes a non-empty file containing log entries")
    func saveLogsWritesFile() async throws {
        _ = try await triggerInstallError()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-test-export-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // Wait briefly for os.Logger entries to flush to the store
        try await Task.sleep(for: .seconds(2))

        let succeeded = await LogExporter.export(to: outputURL)
        #expect(succeeded, "LogExporter.export returned false")

        let data = try Data(contentsOf: outputURL)
        #expect(!data.isEmpty, "Exported log file is empty")

        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("secondchance"), "Exported log does not mention secondchance subsystem")
    }
}

// MARK: - Helpers shared with LogWindowTests

private actor LineCollector {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}
