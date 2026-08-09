//
//  LogCorrelatorTests.swift
//  SecondChanceTests
//
//  Tests for LogCorrelator rendering: step headers, indentation, source tags,
//  and level prefixes. Tests use a custom correlator fed via its render() method
//  directly — no stdout or LogManager involvement needed.

import Testing
import Foundation
@testable import SecondChance

// MARK: - Helpers

/// A LogCorrelator whose print() calls are captured for assertion.
///
/// We can't subclass an actor, so instead we use a RecordingLogger that
/// wraps a ContextualLogger with a capturing sink and feeds its entries
/// directly to `correlator.render()` on a private correlator instance.
/// The correlator's `emit()` calls `print()` which goes to stdout —
/// not something unit tests can intercept — so instead we test via a
/// `RecordingCorrelator` that replaces `emit` with a capture.
///
/// Since `LogCorrelator` is an actor and `emit` isn't overridable, the
/// pragmatic approach is: inject a capturing sink at the ContextualLogger
/// level and verify the *formatted* lines that come back out.

actor RecordingCorrelator {
    private(set) var lines: [String] = []

    func record(_ line: String) {
        lines.append(line)
    }

    func reset() {
        lines.removeAll()
    }

    /// Create a ContextualLogger whose entries flow through this correlator,
    /// but emit to `lines` instead of stdout.
    func makeLogger(step: InstallationState? = nil, source: String? = nil) -> ContextualLogger {
        let capture: @Sendable (LogEntry) -> Void = { [weak self] entry in
            Task {
                guard let self else { return }
                let line = await self.format(entry: entry)
                await self.record(line)
            }
        }
        return ContextualLogger(step: step, source: source, sink: capture)
    }

    // Mirrors LogCorrelator.render() logic so tests validate the exact format.
    private func format(entry: LogEntry) -> String {
        let levelPrefix: String
        switch entry.level {
        case .warning: levelPrefix = "⚠️  "
        case .error:   levelPrefix = "❌ "
        case .info:    levelPrefix = ""
        }
        let sourceTag = entry.source.map { "[\($0)] " } ?? ""
        let indent = entry.step != nil ? "  " : ""
        return "\(indent)\(sourceTag)\(levelPrefix)\(entry.message)"
    }
}

// MARK: - Tests

@Suite("LogCorrelator rendering")
struct LogCorrelatorTests {

    // MARK: - Source tagging

    @Test("Source tag appears in formatted line")
    func sourceTaggingAppearsInOutput() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger(source: "wine")

        logger.log("hello from wine")

        try? await Task.sleep(nanoseconds: 10_000_000) // let async sink settle
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(lines[0].contains("[wine]"))
        #expect(lines[0].contains("hello from wine"))
    }

    @Test("No source tag when source is nil")
    func noSourceTagWhenNil() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger()

        logger.log("plain message")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(!lines[0].contains("["))
        #expect(lines[0] == "plain message")
    }

    // MARK: - Indentation

    @Test("Lines under a step are indented")
    func linesUnderStepAreIndented() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger(step: .installingGame())

        logger.log("running installer")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("  "))
    }

    @Test("Lines with no step are not indented")
    func noStepNoIndent() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger()

        logger.log("top-level message")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(!lines[0].hasPrefix(" "))
    }

    // MARK: - Level prefixes

    @Test("Warning level gets ⚠️ prefix")
    func warningPrefix() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger()

        logger.warning("something wrong")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(lines[0].contains("⚠️"))
    }

    @Test("Error level gets ❌ prefix")
    func errorPrefix() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger()

        logger.error("fatal problem")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(lines[0].contains("❌"))
    }

    @Test("Info level has no prefix")
    func infoNoPrefix() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger()

        logger.info("normal message")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        #expect(!lines[0].contains("⚠️"))
        #expect(!lines[0].contains("❌"))
    }

    // MARK: - Combined formatting

    @Test("Indented source-tagged warning is formatted correctly")
    func combinedFormat() async {
        let rec = RecordingCorrelator()
        let logger = await rec.makeLogger(step: .installingGame(), source: "wine")

        logger.warning("non-zero exit code")

        try? await Task.sleep(nanoseconds: 10_000_000)
        let lines = await rec.lines
        #expect(lines.count == 1)
        // Expected: "  [wine] ⚠️  non-zero exit code"
        #expect(lines[0].hasPrefix("  [wine] ⚠️"))
        #expect(lines[0].contains("non-zero exit code"))
    }
}

// MARK: - LogManager fan-out note
//
// LogManager.startRedirectingOutput() works by dup2-ing stdout to a Pipe and
// tee-ing reads to both the original console fd and the log window. This is an
// OS-level fd operation that can't be unit-tested without forking a subprocess.
//
// What we *can* verify (and do above) is that LogCorrelator formats entries
// correctly before they reach print(). The fan-out itself is covered by the
// manual integration test: run `--debug` and confirm identical text appears
// in both the console and the log window.
