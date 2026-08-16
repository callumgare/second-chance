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

    // MARK: - Import parsing

    @Test("Parser reads both export formats")
    func parserReadsExportFormats() {
        let full = LogFormatter.parse(
            line: "2026-02-16T00:00:00.000Z  warning  au.gare.callum.second-chance.SecondChance.GameDetector  disk not found — Error: I/O"
        )
        #expect(full?.level == "warning")
        #expect(full?.category == "GameDetector", "full-format labels reduce to their last component")
        #expect(full?.message == "disk not found — Error: I/O")
        #expect(full?.time.range(of: #"^\d{2}:\d{2}:\d{2}\.\d{3}$"#, options: .regularExpression) != nil,
                "ISO timestamps convert to local time-of-day, got: \(full?.time ?? "nil")")

        let compact = LogFormatter.parse(line: "12:34:56.789  error  GameLauncher  boom")
        #expect(compact?.time == "12:34:56.789")
        #expect(compact?.level == "error")
        #expect(compact?.category == "GameLauncher")
        #expect(compact?.message == "boom")
    }

    @Test("Lines without a known level are not parsed as log lines")
    func parserRejectsNonLogLines() {
        #expect(LogFormatter.parse(line: "12:34:56.789  banana  GameLauncher  boom") == nil,
                "unknown level token must not parse")
        #expect(LogFormatter.parse(line: "just some text") == nil)
    }

    @Test("LogRow.parse keeps multi-line messages with their entry")
    func parseKeepsMultiLineMessages() {
        let entry = Entry(
            seq: 1,
            timestamp: Date(timeIntervalSince1970: 1_771_200_000),
            level: "notice",
            label: "au.gare.callum.second-chance.Wine",
            message: "step 1\nstep 2",
            error: nil
        )
        // Exactly what an export writes to disk (trailing newline included).
        let rows = LogRow.parse(fileContents: LogFormatter.full(entry: entry) + "\n")
        #expect(rows.count == 1, "multi-line message should stay one row, got \(rows.count)")
        #expect(rows.first?.message.contains("step 1\nstep 2") == true)
    }

    @Test("Unparseable text becomes fallback rows")
    func parseFallsBackOnPlainText() {
        let rows = LogRow.parse(fileContents: "hello\nworld")
        #expect(rows.count == 2)
        #expect(rows.map(\.message) == ["hello", "world"])
    }

    // MARK: - Importing and resuming

    /// Writes a one-entry exported-format log file containing `marker`.
    private func makeLogFile(marker: String) throws -> URL {
        let entry = Entry(
            seq: 1,
            timestamp: Date(timeIntervalSince1970: 1_771_200_000),
            level: "error",
            label: "au.gare.callum.second-chance.Imported",
            message: marker,
            error: nil
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-import-test-\(UUID().uuidString).log")
        try (LogFormatter.full(entry: entry) + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func occurrences(of marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }

    @Test("Importing an unreadable or empty file fails gracefully")
    func importFailureShowsAlert() {
        let model = LogDisplayModel()
        let ok = model.importLogFile(at: URL(fileURLWithPath: "/nonexistent/sc-\(UUID().uuidString).log"))
        #expect(!ok)
        #expect(model.showImportFailedAlert)
        #expect(model.source == .live, "a failed import must not leave the window in file mode")
    }

    @Test("Import shows the file's logs and pauses all live logs")
    func importShowsFileAndPausesLive() async throws {
        let liveMarker = "ImportLive-\(UUID().uuidString)"
        let fileMarker = "ImportFile-\(UUID().uuidString)"
        let duringMarker = "DuringFile-\(UUID().uuidString)"
        let window = LogWindow()

        Logger(label: "au.gare.callum.second-chance.SecondChance.test").notice("\(liveMarker)")

        await MainActor.run { window.showLogWindow(title: "Test - Import") }
        try await Task.sleep(for: .milliseconds(400))

        let url = try makeLogFile(marker: fileMarker)
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = await MainActor.run { window.display.importLogFile(at: url) }
        #expect(ok)
        try await Task.sleep(for: .milliseconds(200))

        var text = await MainActor.run { window.displayedTextForTesting }
        #expect(text.contains(fileMarker), "imported marker missing after import")
        #expect(!text.contains(liveMarker), "live history must not be shown while a file is displayed")

        // Live emissions while in file mode stay hidden.
        Logger(label: "au.gare.callum.second-chance.SecondChance.test").error("\(duringMarker)")
        try await Task.sleep(for: .milliseconds(400))
        text = await MainActor.run { window.displayedTextForTesting }
        #expect(!text.contains(duringMarker), "live line leaked into the imported-file view")

        await MainActor.run { window.hideLogWindow() }
    }

    @Test("Closing the imported-file bar resumes live logs without loss or duplication")
    func closingFileBarResumesLive() async throws {
        let liveMarker = "ResumeLive-\(UUID().uuidString)"
        let fileMarker = "ResumeFile-\(UUID().uuidString)"
        let duringMarker = "ResumeDuring-\(UUID().uuidString)"
        let window = LogWindow()

        Logger(label: "au.gare.callum.second-chance.SecondChance.test").notice("\(liveMarker)")

        await MainActor.run { window.showLogWindow(title: "Test - Resume") }
        try await Task.sleep(for: .milliseconds(400))

        let url = try makeLogFile(marker: fileMarker)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await MainActor.run { window.display.importLogFile(at: url) }

        Logger(label: "au.gare.callum.second-chance.SecondChance.test").error("\(duringMarker)")
        try await Task.sleep(for: .milliseconds(200))

        // Close the imported-file bar.
        await MainActor.run { window.display.source = .live }
        try await Task.sleep(for: .milliseconds(400))

        let text = await MainActor.run { window.displayedTextForTesting }
        #expect(!text.contains(fileMarker), "file rows must be gone after closing the bar")
        #expect(occurrences(of: liveMarker, in: text) == 1,
                "live marker appeared \(occurrences(of: liveMarker, in: text))× — expected exactly 1")
        #expect(occurrences(of: duringMarker, in: text) == 1,
                "entries emitted while the file was open must replay exactly once")

        await MainActor.run { window.hideLogWindow() }
    }

    @Test("File view survives close/reopen without duplicating or reverting")
    func fileViewSurvivesReopen() async throws {
        let liveMarker = "ReopenLive-\(UUID().uuidString)"
        let fileMarker = "ReopenFile-\(UUID().uuidString)"
        let window = LogWindow()

        Logger(label: "au.gare.callum.second-chance.SecondChance.test").notice("\(liveMarker)")
        await MainActor.run { window.showLogWindow(title: "Test - Reopen File") }
        try await Task.sleep(for: .milliseconds(400))

        let url = try makeLogFile(marker: fileMarker)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await MainActor.run { window.display.importLogFile(at: url) }

        await MainActor.run {
            window.hideLogWindow()
            window.showLogWindow(title: "Test - Reopen File")
        }
        try await Task.sleep(for: .milliseconds(400))

        let text = await MainActor.run { window.displayedTextForTesting }
        #expect(occurrences(of: fileMarker, in: text) == 1, "imported rows duplicated on reopen")
        #expect(!text.contains(liveMarker), "reopen must not revert to live logs while a file is displayed")

        await MainActor.run {
            window.display.source = .live  // return to live before teardown
            window.hideLogWindow()
        }
    }

    @Test("File-mode export text renders the displayed rows")
    func fileModeExportText() {
        let model = LogDisplayModel()
        model.rows = LogRow.parse(fileContents: "12:34:56.789  error  GameLauncher  boom\n")
        model.source = .importedFile(URL(fileURLWithPath: "/tmp/game.log"))
        #expect(model.displayedExportText == "12:34:56.789  error  GameLauncher  boom\n")
    }
}
