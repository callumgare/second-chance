import Foundation
import Testing
@testable import SecondChanceKit

@Suite("The helpers' report file")
struct HelperReportFileTests {
    @Test("Whole lines are taken, and one still being written waits")
    func takeLines() {
        var buffer = Data("second-chance-helper[QuitWatch] notice: armed\nsecond-chance-helper[Nat".utf8)
        #expect(HelperReportFile.takeLines(from: &buffer) == ["second-chance-helper[QuitWatch] notice: armed"])
        #expect(String(decoding: buffer, as: UTF8.self) == "second-chance-helper[Nat")
        buffer.append(Data("iveFullscreen] notice: armed\n".utf8))
        #expect(HelperReportFile.takeLines(from: &buffer) == ["second-chance-helper[NativeFullscreen] notice: armed"])
        #expect(buffer.isEmpty)
    }

    @Test("Lines appended to the file are handed on as they come")
    func readsAppendedLines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = HelperReportFile(url: HelperReportFile.url(in: directory))
        let seen = Seen()
        file.start { seen.add($0) }
        defer { file.stop() }

        try Data("a\nb\n".utf8).write(to: file.url)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\n".utf8))
        try handle.close()

        let deadline = Date().addingTimeInterval(5)
        while seen.lines.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(seen.lines == ["a", "b", "c"])
    }
}

private nonisolated final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var lines: [String] { lock.withLock { all } }
    func add(_ line: String) { lock.withLock { all.append(line) } }
}
