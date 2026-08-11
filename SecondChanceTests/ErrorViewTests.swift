//
//  ErrorViewTests.swift
//  SecondChanceTests
//
//  Tests for ErrorView's "Show Logs" and "Save Logs" functionality.
//  Emits log entries via os.Logger with the secondchance subsystem, then
//  verifies the log window and log export surface them correctly.

import Testing
import Foundation
import os
@testable import SecondChance

private let testLogger = Logger(subsystem: "com.secondchance", category: "ErrorViewTests")

@Suite("ErrorView log actions", .serialized)
struct ErrorViewTests {

    // MARK: - Helpers

    /// Emit a few log entries so LogWindow / LogExporter have something to find.
    private func emitTestLogEntries() {
        testLogger.notice("ErrorViewTests: simulated installation started")
        testLogger.error("ErrorViewTests: simulated installation error occurred")
    }

    // MARK: - Show Logs

    @Test("Show Logs opens log window and it contains installation log entries")
    func showLogsOpensWindow() async throws {
        let collector = LineCollector()
        await MainActor.run {
            LogWindow.shared.onLine = { line in Task { await collector.add(line) } }
        }
        defer {
            Task { @MainActor in
                LogWindow.shared.onLine = nil
                LogWindow.shared.stopStreaming()
            }
        }

        emitTestLogEntries()

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
        emitTestLogEntries()

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
