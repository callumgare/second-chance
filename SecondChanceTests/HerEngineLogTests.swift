//
//  HerEngineLogTests.swift
//  SecondChanceTests
//
//  Reading the later Her Interactive games' own verdict on how they exited.

import Foundation
import Testing
@testable import SecondChance

@Suite("Her Interactive engine log")
struct HerEngineLogTests {
    /// The tail of a real run's Debug.LOG (The Deadly Device), CRLF and all.
    static let cleanRun = [
        "00028 0015:41:16.191:  Attempting to save game 'Attic.hia'",
        "00029 0015:41:16.192:  CSound::CloseSoundSystem()...",
        "00030 0015:41:16.272:  ExitInstance(), good exit...",
        "00031 0015:41:16.272:  CSound::CloseSoundSystem()...",
    ].joined(separator: "\r\n") + "\r\n"

    @Test("A log that got through ExitInstance reports a clean exit")
    func cleanExit() {
        #expect(HerEngineLog.reportsCleanExit(Self.cleanRun))
    }

    @Test("A log that stops before ExitInstance doesn't")
    func stoppedEarly() {
        let cut = Self.cleanRun.components(separatedBy: "\r\n").prefix(2).joined(separator: "\r\n")
        #expect(!HerEngineLog.reportsCleanExit(cut))
        #expect(!HerEngineLog.reportsCleanExit(""))
    }

    @Test("Finds the clean log in the game's Documents folder, but only one written since the launch")
    func findsFreshLog() throws {
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerEngineLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: documents) }
        let folder = documents.appendingPathComponent("The Deadly Device")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Other things a Documents folder holds
        try Data("wine".utf8).write(to: documents.appendingPathComponent("game-engine"))
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Empty"), withIntermediateDirectories: true)

        let log = folder.appendingPathComponent(HerEngineLog.fileName)
        try Data(Self.cleanRun.utf8).write(to: log)
        let written = Date()
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: log.path)

        let found = HerEngineLog.cleanExitLog(inDocuments: documents, since: written.addingTimeInterval(-30))
        #expect(found?.resolvingSymlinksInPath() == log.resolvingSymlinksInPath())
        // A wrapp's Documents is a link to its saves folder
        let link = documents.deletingLastPathComponent().appendingPathComponent("HerEngineLogTests-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: documents)
        defer { try? FileManager.default.removeItem(at: link) }
        let foundThroughLink = HerEngineLog.cleanExitLog(inDocuments: link, since: written.addingTimeInterval(-30))
        #expect(foundThroughLink?.resolvingSymlinksInPath() == log.resolvingSymlinksInPath())
        // A log left by an earlier launch says nothing about this one
        #expect(HerEngineLog.cleanExitLog(inDocuments: documents, since: written.addingTimeInterval(30)) == nil)
    }

    @Test("A game without the log, or a missing Documents folder, finds nothing")
    func noLog() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("HerEngineLogTests-missing-\(UUID().uuidString)")
        #expect(HerEngineLog.cleanExitLog(inDocuments: missing, since: .distantPast) == nil)
    }
}
