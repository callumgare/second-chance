import Testing
import Foundation
@testable import SecondChance

@Suite("Structured log output")
struct StructuredLogTests {

    private let entry = Entry(
        seq: 42,
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        level: "error",
        label: "au.gare.callum.second-chance.Shared.Wine",
        message: "0124:err:module:import_dll Loading library Ndui.dll failed",
        error: nil,
        metadata: ["pid": "1237", "program": "wine setup.exe"],
        stage: "Game installing"
    )

    @Test("JSON lines carry level, category, stage, metadata and run")
    func jsonLine() throws {
        let line = try #require(JSONLinesLogSink.encode(entry))
        #expect(line.hasSuffix("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["level"] as? String == "error")
        #expect(object["category"] as? String == "Wine")
        #expect(object["stage"] as? String == "Game installing")
        #expect((object["metadata"] as? [String: String])?["pid"] == "1237")
        #expect(object["run"] as? String == RunContext.runID)
        #expect(object["seq"] as? Int == 42)
    }

    @Test("The full format appends metadata and still parses")
    func fullFormat() throws {
        let line = LogFormatter.full(entry: entry)
        #expect(line.hasSuffix(" {pid=1237 program=wine setup.exe}"))
        let fields = try #require(LogFormatter.parse(line: line))
        #expect(fields.level == "error")
        #expect(fields.category == "Wine")
    }
}
