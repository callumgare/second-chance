import Testing
import Foundation
@testable import SecondChance

@Suite("Run context header")
struct RunContextTests {

    @Test("The header names the build, machine, session and Wine settings")
    func header() {
        let lines = RunContext.headerLines(extra: [("game", "Test")])
        #expect(lines[0].contains("run \(RunContext.runID)"))
        #expect(lines[1].hasPrefix("macOS "))
        #expect(lines[2].contains("WINEDEBUG="))
        #expect(lines.last == "game: Test")
    }

    @Test("The run ID is exported for child processes")
    func runIDExported() {
        #expect(ProcessInfo.processInfo.environment["SECOND_CHANCE_RUN_ID"] == RunContext.runID)
    }

    @Test("Directory sizes add up regular files")
    func directorySize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dirsize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 1_000).write(to: dir.appendingPathComponent("a"))
        try Data(count: 500).write(to: dir.appendingPathComponent("sub/b"))
        let size = DirectorySize.measure(dir)
        #expect(size == DirectorySize(bytes: 1_500, files: 2))
    }
}
