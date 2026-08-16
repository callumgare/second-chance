//
//  ErrorViewTests.swift
//  SecondChanceTests
//
//  Tests for ErrorView's "Show Logs" and "Save Logs" functionality.
//  Emits log entries through the host app's bootstrapped logging system and
//  verifies the log window and log export surface them synchronously.

import Testing
import Foundation
import Logging
@testable import SecondChance

private let testLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.ErrorViewTests")

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
        emitTestLogEntries()

        await MainActor.run {
            LogWindow.shared.onLine = { line in Task { await collector.add(line) } }
            LogWindow.shared.showLogWindow(title: "Test - Installation Log")
        }

        // The snapshot is delivered synchronously on show; allow a brief hop
        // for the collector tasks.
        try await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            LogWindow.shared.onLine = nil
            LogWindow.shared.hideLogWindow()
        }

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

        let succeeded = await LogExporter.export(to: outputURL)
        #expect(succeeded, "LogExporter.export returned false")

        let data = try Data(contentsOf: outputURL)
        #expect(!data.isEmpty, "Exported log file is empty")

        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("au.gare.callum.second-chance"), "Exported log does not mention the app subsystem")
        #expect(text.contains("ErrorViewTests: simulated installation error occurred"),
                "Exported log does not contain the emitted test entry")
    }
}

// MARK: - Helpers shared with LogWindowTests

actor LineCollector {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
    func contains(text: String) -> Bool { lines.contains { $0.contains(text) } }
}
