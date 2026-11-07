import ArgumentParser
import Foundation
import Testing
@testable import SCKit

struct PuppetStartTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puppet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test("A new start of a session empties its folder")
    func startsFresh() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("game")
        try write("save", to: folder.appendingPathComponent("app-support/Bioscopia.rup"))
        try write("log", to: folder.appendingPathComponent("wrapp.log"))
        try PuppetSession.clearFolder("game", keepingSaves: false, in: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("--keep-saves keeps the last session's saves and nothing else of it")
    func keepsSaves() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("game")
        try write("save", to: folder.appendingPathComponent("app-support/Bioscopia.rup"))
        try write("engine", to: folder.appendingPathComponent("home/Library/Preferences/scummvm.ini"))
        try write("reg", to: folder.appendingPathComponent("prefix/user.reg"))
        try write("log", to: folder.appendingPathComponent("wrapp.log"))
        try write("{}", to: folder.appendingPathComponent("session.json"))
        try PuppetSession.clearFolder("game", keepingSaves: true, in: root)
        #expect(try String(contentsOf: folder.appendingPathComponent("app-support/Bioscopia.rup"), encoding: .utf8) == "save")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("home/Library/Preferences/scummvm.ini").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("prefix/user.reg").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("wrapp.log").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path))
        // Nothing set aside is left beside the sessions.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["game"])
        // With no session before it, there's nothing to keep.
        try PuppetSession.clearFolder("new", keepingSaves: true, in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("new").path).isEmpty)
    }

    @Test("start --debug takes a wrapp's debug values, Wine's channels among them")
    func debugValues() throws {
        let start = try PuppetStartCommand.parse(["game", "--wrapp", "/Applications/Game.app", "--debug", "wine=+seh,+d3d9", "--keep-saves"])
        #expect(start.keepSaves)
        #expect(try start.debug.effect().environment == ["SECOND_CHANCE_WINEDEBUG": "+seh,+d3d9"])
        #expect(throws: (any Error).self) {
            try PuppetStartCommand.parse(["game", "--wrapp", "/Applications/Game.app", "--debug", "strict-install"])
        }
    }
}
