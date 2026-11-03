import Foundation
import Testing
@testable import ProcessKit
@testable import SecondChanceKit
@testable import WindowsFormats
@testable import WineKit
@testable import WrappFormat
@testable import WrappLogging

@Suite("A wrapp's command line")
struct WrappLaunchOptionsTests {
    @Test("A plain launch asks for nothing")
    func plain() {
        let options = WrappLaunchOptions(arguments: ["/Game.app/Contents/MacOS/WrappTemplate"])
        #expect(!options.debugMode && !options.showsDebugSettings && !options.withoutSteam
                && !options.afterNoDisplay && !options.openedAgain)
    }

    @Test("Each argument is read wherever it comes")
    func each() {
        let options = WrappLaunchOptions(arguments: ["WrappTemplate", "--opened-again", "--debug",
                                                     "--launch-without-steam", "--after-no-display", "--debug-options"])
        #expect(options.debugMode && options.showsDebugSettings && options.withoutSteam
                && options.afterNoDisplay && options.openedAgain)
    }

    @Test("--debug-options doesn't turn on debug mode by itself")
    func debugOptionsAlone() {
        let options = WrappLaunchOptions(arguments: ["WrappTemplate", "--debug-options"])
        #expect(options.showsDebugSettings)
        #expect(!options.debugMode)
    }
}

@Suite("Linking the prefix's Documents to the saves")
struct SavesLinkTests {
    private let root: URL
    private let documents: URL
    private let saves: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("saves-link-\(UUID().uuidString)")
        documents = root.appendingPathComponent("prefix/drive_c/users/player/Documents")
        saves = root.appendingPathComponent("Application Support/game")
        try FileManager.default.createDirectory(at: documents.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
    }

    private func linkTarget() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: documents.path)
    }

    @Test("With nothing there, the link is made")
    func fresh() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try SavesLink.link(documents, to: saves) == nil)
        #expect(try linkTarget() == saves.path)
    }

    @Test("An old link, even to a folder that has gone, is replaced")
    func replacesOldLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: documents.path, withDestinationPath: "/nowhere/at/all")
        try SavesLink.link(documents, to: saves)
        #expect(try linkTarget() == saves.path)
    }

    @Test("A real folder, and the saves in it, is moved aside, never deleted")
    func keepsRealFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: documents.appendingPathComponent("save1.sav"))
        let aside = try #require(try SavesLink.link(documents, to: saves, now: Date(timeIntervalSince1970: 1_000)))
        #expect(aside.lastPathComponent == "Documents (kept 1000)")
        #expect(try Data(contentsOf: aside.appendingPathComponent("save1.sav")) == Data("progress".utf8))
        #expect(try linkTarget() == saves.path)
    }
}
