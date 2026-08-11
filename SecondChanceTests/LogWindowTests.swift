//
//  LogWindowTests.swift
//  SecondChanceTests

import Testing
import Foundation
import os
@testable import SecondChance

@Suite("LogWindow streaming")
struct LogWindowTests {

    actor LineCollector {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
        func contains(text: String) -> Bool { lines.contains { $0.contains(text) } }
    }

    @Test("Log stream delivers entries to onLine callback")
    func streamingDeliversEntries() async throws {
        let marker = "LogWindowTest-\(UUID().uuidString)"
        let window = LogWindow()
        let collector = LineCollector()

        window.onLine = { line in Task { await collector.add(line) } }

        window.startStreaming(pid: ProcessInfo.processInfo.processIdentifier, since: Date())

        // Give log stream time to connect before emitting
        try await Task.sleep(for: .seconds(1))

        Logger(subsystem: "com.secondchance", category: "test").notice("\(marker, privacy: .public)")

        // Poll up to 5 s for the marker to appear
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await collector.contains(text: marker) { break }
            try await Task.sleep(for: .milliseconds(250))
        }

        let found = await collector.contains(text: marker)
        let count = await collector.lines.count
        #expect(found, "log stream did not deliver marker within 5 s — \(count) lines received")
    }
}
