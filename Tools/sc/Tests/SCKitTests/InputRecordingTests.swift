import CoreGraphics
import Foundation
import PuppetProtocol
import Testing
@testable import SCKit

@Suite("Recordings of clicks and keys, and their replay")
struct InputRecordingTests {
    private let header = #"{"exe":"Waverly.exe","format":1,"started":"2026-11-17T10:00:00Z"}"#

    @Test("A press and its release, soon and near, are one click, held as long as the person held it")
    func pressAndReleaseAreAClick() throws {
        let recording = try InputRecording.parse("""
        \(header)
        {"t":1.5,"event":"down","button":"left","x":0.25,"y":0.5}
        {"t":1.62,"event":"up","button":"left","x":0.251,"y":0.5}
        {"t":3,"event":"key","key":"escape"}
        {"t":4,"event":"key","key":"s","mods":"cmd"}
        """)
        #expect(recording.exe == "Waverly.exe")
        #expect(recording.steps == [
            .init(time: 1.5, action: .click(x: 0.25, y: 0.5, button: .left, holdMilliseconds: 120)),
            .init(time: 3, action: .key("escape")),
            .init(time: 4, action: .key("cmd+s")),
        ])
    }

    @Test("A long hold or a drag is replayed as its press and release")
    func longHoldStaysApart() throws {
        let recording = try InputRecording.parse("""
        \(header)
        {"t":1,"event":"down","button":"left","x":0.2,"y":0.2}
        {"t":3,"event":"up","button":"left","x":0.2,"y":0.2}
        {"t":4,"event":"down","button":"right","x":0.2,"y":0.2}
        {"t":4.1,"event":"up","button":"right","x":0.6,"y":0.2}
        """)
        #expect(recording.steps.map(\.action) == [
            .down(x: 0.2, y: 0.2, button: .left), .up(x: 0.2, y: 0.2, button: .left),
            .down(x: 0.2, y: 0.2, button: .right), .up(x: 0.6, y: 0.2, button: .right),
        ])
    }

    @Test("A recording cut off mid-line keeps what came before; a file that isn't one is refused")
    func cutOffAndForeign() throws {
        let cut = try InputRecording.parse("\(header)\n{\"t\":1,\"event\":\"key\",\"key\":\"a\"}\n{\"t\":2,\"ev")
        #expect(cut.steps.count == 1)
        #expect(throws: SCError.self) { try InputRecording.parse("{\"hello\":1}\n") }
    }

    @Test("A share of the picture lands at the same place in a picture of another size and place")
    func sharesOfThePicture() throws {
        // Recorded in a 1512x982 window whose 1310x982 picture sat 101 points in;
        // replayed in a 2560x1440 one, whose picture is 1920x1440 at 320.
        let picture = CGRect(x: 320, y: 0, width: 1920, height: 1440)
        #expect(InputRecording.point(x: 0.5, y: 0.25, picture: picture) == CGPoint(x: 1280, y: 360))
        let request = try InputRecording.request(.click(x: 0, y: 1, button: .left, holdMilliseconds: 90), picture: picture)
        #expect(request == .click(CGPoint(x: 320, y: 1440), button: .left, hold: 90))
    }

    @Test("Wine's fps channel's rates are read from the log")
    func frameRates() {
        let log = """
        12:00:01.000 notice Wine 0124:trace:fps:wined3d_cs_exec_present @ approx 55.90fps
        other line
        12:00:02.000 notice Wine 0124:trace:fps:wined3d_cs_exec_present @ approx 0.48fps
        """
        #expect(InputRecording.frameRates(in: log) == [55.9, 0.48])
        #expect(PuppetReplayCommand.rateSummary([55.9, 0.48, 30]) == "fps median 30.0, min 0.5")
    }

    @Test("A picture given by hand is read as state's picture= is, and a malformed one refused")
    func givenPicture() throws {
        #expect(try PuppetReplayCommand.rect("101,0,1309,982") == CGRect(x: 101, y: 0, width: 1309, height: 982))
        #expect(throws: (any Error).self) { try PuppetReplayCommand.rect("101,0,1309") }
    }

    @Test("A game slower to answer each step as it's played shows it quarter by quarter")
    func reactionTrend() {
        #expect(PuppetReplayCommand.reactionTrend([0.6, 0.8, 2.0, 2.2, 3.5, 3.8, 5.0, 4.9]) == "0.8 s, 2.2 s, 3.8 s, 5.0 s")
        #expect(PuppetReplayCommand.reactionTrend([1, 2]) == nil)
    }
}

@Suite("A puppet session started with the player's saves")
struct PuppetPlayerSavesTests {
    @Test("The player's folder for the wrapp's bundle id is copied into the session's, and theirs left as it was")
    func copiesThePlayersFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("player-saves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Game.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "example.game"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let player = root.appendingPathComponent("player")
        let save = player.appendingPathComponent("example.game/stores/app/wine-documents/Laggy.HiWacSave")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: save)

        let session = root.appendingPathComponent("session/app-support")
        let copied = try PuppetSession.copyPlayerFiles(of: app, into: session, from: player)
        #expect(copied == player.appendingPathComponent("example.game"))
        #expect(try Data(contentsOf: session.appendingPathComponent("example.game/stores/app/wine-documents/Laggy.HiWacSave")) == Data("save".utf8))
        #expect(FileManager.default.fileExists(atPath: save.path))

        try FileManager.default.removeItem(at: player)
        #expect(try PuppetSession.copyPlayerFiles(of: app, into: session, from: player) == nil)
    }
}

@Suite("Where a replay reads the frame rates")
struct PuppetReplayLogTests {
    @Test("The wrapp's own log is the one its output names")
    func wrappLog() {
        let output = "  GUI session (Aqua); WINEDEBUG=err+all,+fps\n  log: /Users/someone/Library/Logs/SecondChance/waverly-academy/launch-20261117-115710.log\nmore"
        #expect(PuppetReplayCommand.wrappLogFile(named: output)?.lastPathComponent == "launch-20261117-115710.log")
        #expect(PuppetReplayCommand.wrappLogFile(named: "nothing here") == nil)
    }
}
