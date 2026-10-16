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
        #expect(DirectorySize.measure(dir) == DirectorySize(bytes: 1_500, files: 2))

        // A folder of links into another counts what they point at, once.
        let links = dir.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("sub").path, withDestinationPath: "../sub")
        #expect(DirectorySize.measure(links) == DirectorySize(bytes: 500, files: 1))

        // A link out of the tree, like a Wine prefix's z: drive, isn't walked.
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("sub/z:").path, withDestinationPath: "/")
        #expect(DirectorySize.measure(dir) == DirectorySize(bytes: 1_500, files: 2))
    }
}
