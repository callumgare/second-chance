//
//  LogWindowTests.swift
//  SecondChanceTests

import Testing
import Foundation
import Logging
@testable import SecondChance

@Suite("LogWindow streaming", .serialized)
struct LogWindowTests {

    actor LineCollector {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
        func contains(text: String) -> Bool { lines.contains { $0.contains(text) } }
    }

    @Test("Log window delivers entries to onLine callback")
    func windowDeliversEntries() async throws {
        let marker = "LogWindowTest-\(UUID().uuidString)"
        let window = LogWindow()
        let collector = LineCollector()

        await MainActor.run {
            window.onLine = { line in Task { await collector.add(line) } }
        }

        // Emit through the host app's bootstrapped logging system, then show
        // the window: the LogStore snapshot carries the marker as history.
        Logger(label: "au.gare.callum.second-chance.SecondChance.test").notice("\(marker)")

        await MainActor.run {
            window.showLogWindow(title: "Test - Log Window")
        }

        // The snapshot is delivered synchronously on show; allow a brief hop
        // for the collector tasks, then assert.
        try await Task.sleep(for: .milliseconds(200))

        await MainActor.run {
            window.hideLogWindow()
        }

        let found = await collector.contains(text: marker)
        let count = await collector.lines.count
        #expect(found, "log window did not deliver marker — \(count) lines received")
    }

    @Test("Live entries stream to an open window")
    func liveEntriesStream() async throws {
        let marker = "LogWindowLiveTest-\(UUID().uuidString)"
        let window = LogWindow()
        let collector = LineCollector()

        await MainActor.run {
            window.onLine = { line in Task { await collector.add(line) } }
            window.showLogWindow(title: "Test - Live Streaming")
        }

        // Emitted after subscribing — must arrive via the live batch path.
        Logger(label: "au.gare.callum.second-chance.SecondChance.test").notice("\(marker)")

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await collector.contains(text: marker) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run {
            window.hideLogWindow()
        }

        let found = await collector.contains(text: marker)
        #expect(found, "live entry did not reach the open window within 2 s")
    }

    @Test("Reopening the window does not duplicate history")
    func reopenDoesNotDuplicateHistory() async throws {
        let marker = "LogWindowReopenTest-\(UUID().uuidString)"
        // Emit before opening so the marker is part of the history snapshot.
        Logger(label: "au.gare.callum.second-chance.SecondChance.test").notice("\(marker)")

        let window = LogWindow()

        func occurrences(of marker: String) -> Int {
            window.displayedTextForTesting.components(separatedBy: marker).count - 1
        }

        await MainActor.run {
            window.showLogWindow(title: "Test - Reopen")
        }
        // Allow the coalesced flush (100 ms deadline) to render the snapshot.
        try await Task.sleep(for: .milliseconds(400))
        let firstOpenCount = await MainActor.run { occurrences(of: marker) }
        #expect(firstOpenCount == 1, "marker appeared \(firstOpenCount)× on first open — expected exactly 1")

        // Close and reopen: the controller (and its text storage) persists,
        // and the snapshot replays. The display must start fresh, not append.
        await MainActor.run {
            window.hideLogWindow()
            window.showLogWindow(title: "Test - Reopen")
        }
        try await Task.sleep(for: .milliseconds(400))
        let secondOpenCount = await MainActor.run { occurrences(of: marker) }
        #expect(secondOpenCount == 1, "marker appeared \(secondOpenCount)× after reopen — history duplicated")

        // And once more for good measure (the bug compounded per open).
        await MainActor.run {
            window.hideLogWindow()
            window.showLogWindow(title: "Test - Reopen")
        }
        try await Task.sleep(for: .milliseconds(400))
        let thirdOpenCount = await MainActor.run { occurrences(of: marker) }
        #expect(thirdOpenCount == 1, "marker appeared \(thirdOpenCount)× after second reopen — history duplicated")

        await MainActor.run {
            window.hideLogWindow()
        }
    }

    // MARK: - Row model

    @Test("LogRow carries structured fields and appends the error in-band")
    func logRowFormatting() {
        let entry = Entry(
            seq: 42,
            timestamp: Date(timeIntervalSince1970: 1_771_200_000),
            level: "warning",
            label: "au.gare.callum.second-chance.SecondChance.GameDetector",
            message: "disk not found",
            error: "I/O"
        )
        let row = LogRow(entry: entry)
        #expect(row.id == 42)
        #expect(row.time == LogFormatter.time(entry: entry))
        #expect(row.level == "warning")
        #expect(row.category == "GameDetector")
        #expect(row.message == "disk not found — Error: I/O")
        #expect(row.compactLine.hasPrefix("\(row.time)  warning  GameDetector  disk not found"))

        let clean = LogRow(entry: Entry(
            seq: 43,
            timestamp: Date(timeIntervalSince1970: 1_771_200_000),
            level: "trace",
            label: "Bare",
            message: "msg",
            error: nil
        ))
        #expect(clean.message == "msg", "no error suffix without an error")
        #expect(clean.level == "debug", "trace coalesces to debug")
        #expect(clean.category == "Bare", "labels without a dot pass through unchanged")
    }

    // MARK: - Level filter

    @Test("Level filter thresholds")
    func levelFilterThresholds() {
        #expect(LogLevelFilter.all.includes(level: "trace"))
        #expect(LogLevelFilter.all.includes(level: "critical"))

        #expect(!LogLevelFilter.warnings.includes(level: "notice"))
        #expect(LogLevelFilter.warnings.includes(level: "warning"))
        #expect(LogLevelFilter.warnings.includes(level: "error"))
        #expect(LogLevelFilter.warnings.includes(level: "critical"))

        #expect(!LogLevelFilter.errors.includes(level: "warning"))
        #expect(LogLevelFilter.errors.includes(level: "error"))
        #expect(LogLevelFilter.errors.includes(level: "critical"))
    }
}
