//
//  ContextualLoggerTests.swift
//  SecondChanceTests
//
//  Unit tests for ContextualLogger. Verifies context stamping (step/source),
//  chaining returns a new logger without mutating the original, and level
//  handling.

import Testing
import Foundation
@testable import SecondChance

@Suite("ContextualLogger")
struct ContextualLoggerTests {

    // MARK: - Context stamping

    @Test("Log entries carry the bound step and source")
    func stepAndSourceStamping() {
        let captured = CapturedEntries()
        let logger = ContextualLogger(
            step: .installingGame(),
            source: "wine",
            sink: { captured.entries.append($0) }
        )

        logger.log("Running installer")

        #expect(captured.entries.count == 1)
        let entry = captured.entries[0]
        #expect(entry.source == "wine")
        #expect(entry.message == "Running installer")
        #expect(entry.level == .info)
        guard case .installingGame = entry.step else {
            Issue.record("Expected .installingGame step")
            return
        }
    }

    @Test("Chaining step().source() binds context without mutating the original")
    func chainingDoesNotMutateOriginal() {
        let captured = CapturedEntries()
        let root = ContextualLogger(sink: { captured.entries.append($0) })

        let child = root.step(.detectingGame()).source("exiftool")

        // The root logger should still have no context.
        #expect(root.step == nil)
        #expect(root.source == nil)

        // The child logger should carry the bound context.
        #expect(child.source == "exiftool")
        guard case .detectingGame = child.step else {
            Issue.record("Expected .detectingGame step on child")
            return
        }

        // Emitting from root should produce a context-less entry.
        root.log("from root")
        // Emitting from child should produce a context-stamped entry.
        child.log("from child")

        #expect(captured.entries.count == 2)
        #expect(captured.entries[0].step == nil)
        #expect(captured.entries[0].source == nil)
        #expect(captured.entries[1].source == "exiftool")
    }

    // MARK: - Levels

    @Test("Level helpers set the correct level")
    func levelHelpers() {
        let captured = CapturedEntries()
        let logger = ContextualLogger(sink: { captured.entries.append($0) })

        logger.info("i")
        logger.warning("w")
        logger.error("e")

        #expect(captured.entries.map(\.level) == [.info, .warning, .error])
    }

    @Test("atLevel changes the default level for subsequent logs")
    func atLevel() {
        let captured = CapturedEntries()
        let logger = ContextualLogger(sink: { captured.entries.append($0) })

        let warningLogger = logger.atLevel(.warning)
        warningLogger.log("defaulted")
        warningLogger.error("explicit")

        #expect(captured.entries[0].level == .warning)
        #expect(captured.entries[1].level == .error)
    }

    // MARK: - Formatting

    @Test("Formatted line includes step and source prefixes")
    func formattedIncludesContext() {
        let entry = LogEntry(
            step: .installingGame(),
            source: "wine",
            level: .info,
            message: "hello",
            timestamp: Date()
        )
        let line = entry.formatted()
        #expect(line.contains("wine"))
        #expect(line.contains("hello"))
    }

    @Test("Formatted line includes level marker for warnings and errors")
    func formattedLevelMarkers() {
        let warn = LogEntry(step: nil, source: nil, level: .warning, message: "m", timestamp: Date())
        let err = LogEntry(step: nil, source: nil, level: .error, message: "m", timestamp: Date())

        #expect(warn.formatted().contains("⚠️"))
        #expect(err.formatted().contains("❌"))
    }
}

// MARK: - Test helper

private final class CapturedEntries {
    var entries: [LogEntry] = []
}
