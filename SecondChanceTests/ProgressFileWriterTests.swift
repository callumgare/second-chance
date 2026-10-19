//
//  ProgressFileWriterTests.swift
//  SecondChanceTests
//
//  The JSON-lines progress stream `sc wrapp build` and `sc test integration`
//  follow. Its shape is a contract with Tools/sc (ProgressRecord), so the
//  field names are asserted here.

import Foundation
import Testing
@testable import SecondChance

@Suite("Progress file writer")
struct ProgressFileWriterTests {
    private func records(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test("Bus events become stage, completed and failed lines")
    func busEventsBecomeLines() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try #require(ProgressFileWriter(path: url.path))
        let bus = EventBus<AppEvent>()
        await writer.subscribe(to: bus)

        await bus.publishWrappBuild(.progress(.installingGame(substep: "Running setup.exe", elapsedSeconds: nil)))
        await bus.publishWrappBuild(.completed(wrappPath: URL(fileURLWithPath: "/tmp/Nancy Drew - X.app")))
        await bus.publishWrappBuild(.failed(.installerNotFound))

        let lines = try records(at: url)
        #expect(lines.count == 3)
        #expect(lines[0]["event"] as? String == "stage")
        #expect(lines[0]["stage"] as? String == "installingGame")
        #expect(lines[0]["text"] as? String == "Game installing — Running setup.exe")
        #expect(lines[0]["fraction"] as? Double == 0.5)
        #expect(lines[1]["event"] as? String == "completed")
        #expect(lines[1]["path"] as? String == "/tmp/Nancy Drew - X.app")
        #expect(lines[2]["event"] as? String == "failed")
        #expect((lines[2]["message"] as? String)?.isEmpty == false)
    }

    @Test("Subscribing twice still writes each event once")
    func subscribingTwiceIsANoOp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try #require(ProgressFileWriter(path: url.path))
        let bus = EventBus<AppEvent>()
        await writer.subscribe(to: bus)
        await writer.subscribe(to: bus)
        await bus.publishWrappBuild(.progress(.savingApp()))
        #expect(try records(at: url).count == 1)
    }

    @Test("States the user picks in the UI have no stage")
    func selectionStatesAreSkipped() {
        #expect(ProgressFileWriter.stageName(.idle) == nil)
        #expect(ProgressFileWriter.stageName(.selectingSource) == nil)
        #expect(ProgressFileWriter.stageName(.detectingGame()) == "detectingGame")
    }

    @Test("Records written directly are appended as JSON lines")
    func directWritesAppend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try #require(ProgressFileWriter(path: url.path))
        writer.write(["event": "game", "slug": "stay-tuned", "phase": "started"])
        writer.write(["event": "game", "slug": "stay-tuned", "phase": "finished", "result": "passed", "seconds": 1.5])
        let lines = try records(at: url)
        #expect(lines.map { $0["phase"] as? String } == ["started", "finished"])
        #expect(lines[1]["result"] as? String == "passed")
    }

    @Test("Two writers on one file keep each other's records")
    func twoWritersAppend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = try #require(ProgressFileWriter(path: url.path))
        let steam = try #require(ProgressFileWriter(path: url.path))
        disk.write(["event": "game", "slug": "stay-tuned", "phase": "started"])
        steam.write(["event": "game", "slug": "old-clock", "source": "steam", "phase": "started"])
        disk.write(["event": "game", "slug": "stay-tuned", "phase": "finished", "result": "passed", "seconds": 1.5])
        #expect(try records(at: url).map { $0["slug"] as? String } == ["stay-tuned", "old-clock", "stay-tuned"])
    }
}
