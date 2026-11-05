import Foundation
import Testing
@testable import SecondChance

@Suite("Integration logs read from files")
struct SystemLogReaderTests {
    // As a wrapp's launch log has them (RotatingLogFile, the full format).
    private let launchLog = """
        2026-11-05T10:40:23.203Z  notice  au.gare.callum.second-chance.WrappTemplate.PuppetServer  [Puppet] Listening on /tmp/p/wrapp.sock
        2026-11-05T10:40:31.896Z  notice  au.gare.callum.second-chance.WrappTemplate.GameLauncher  [Helpers] Puppet control armed (armed in scummvm)
        2026-11-05T10:40:34.348Z  debug  au.gare.callum.second-chance.Shared.Reporting  Failure reports are off:  driven by WrappPuppeteer
        a message's second line

        """

    @Test("A full-format log's lines become compact ones, with the process before the category")
    func compactFromFile() throws {
        let lines = SystemLogReader.compactLines(fromLogFile: launchLog, process: "WrappTemplate")
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[1].hasSuffix("  notice  WrappTemplate/GameLauncher  [Helpers] Puppet control armed (armed in scummvm)"))
        #expect(lines[1].range(of: #"^\d\d:\d\d:\d\d\.\d{3}  "#, options: .regularExpression) != nil)
        // A message with two spaces in it is kept whole; a continuation line as it is.
        #expect(lines[2].hasSuffix("  debug  WrappTemplate/Reporting  Failure reports are off:  driven by WrappPuppeteer"))
        #expect(lines[3] == "a message's second line")
        #expect(SystemLogReader.compactLines(fromLogFile: "", process: "WrappTemplate").isEmpty)
    }

    @Test("The game's log is the launch logs begun since the run started, oldest first")
    func gameLogSince() throws {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("sc-logs-\(UUID().uuidString)")
        let folder = logs.appendingPathComponent("scarlet-hand")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let start = Date()
        func write(_ name: String, created: Date, armed: String) throws {
            let file = folder.appendingPathComponent(name)
            try "2026-11-05T10:40:31.896Z  notice  au.gare.callum.second-chance.WrappTemplate.GameLauncher  \(armed)\n"
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
        }
        try write("launch-20261105-100000.log", created: start.addingTimeInterval(-600), armed: "an earlier run")
        try write("launch-20261105-104022.log", created: start.addingTimeInterval(2), armed: "this run")
        try write("launch-20261105-104500.log", created: start.addingTimeInterval(200), armed: "this run, relaunched")
        try "not a launch log".write(to: folder.appendingPathComponent("crash-marker"), atomically: true, encoding: .utf8)

        let text = String(decoding: SystemLogReader.gameLog(slug: "scarlet-hand", since: start, logs: logs), as: UTF8.self)
        #expect(!text.contains("an earlier run"))
        let first = try #require(text.range(of: "this run"))
        let second = try #require(text.range(of: "this run, relaunched"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(SystemLogReader.gameLog(slug: "no-such-game", since: start, logs: logs).isEmpty)
    }
}
