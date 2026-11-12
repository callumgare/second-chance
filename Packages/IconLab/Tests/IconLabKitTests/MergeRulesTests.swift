import Foundation
import Testing
@testable import IconLabKit

// What the person says about merging search results, applied over the automatic merge.

@Suite struct MergeRulesTests {
    let ours = hit("secondchance", "tivola/webmaster", "Webmaster", year: 1999)
    let wikidata = hit("wikidata", "Q1", "Webmaster", year: 1999)
    let lutris = hit("lutris", "webmaster-fantastic", "Webmaster - Fantastic Adventures in the World of the Internet", year: 1999)
    let archive = hit("internetarchive", "webmaster2000", "Webmaster", year: 2000)

    @Test func hostsProgramMergesAutomaticallyAndLeads() {
        let results = MergeRules().apply([wikidata, ours])
        #expect(results.count == 1)
        #expect(results.first?.bundleId == "tivola/webmaster")
        #expect(results.first?.title == "Webmaster")
    }

    @Test func mergeJoinsWhatTheAutomaticMergeMissed() {
        var rules = MergeRules()
        #expect(rules.apply([ours, lutris]).count == 2)
        rules.merge([MergeRules.key(ours), MergeRules.key(lutris)])
        let results = rules.apply([ours, lutris, archive])
        let merged = results.first { $0.mergedByYou == true }
        #expect(merged?.hits.count == 3)   // the archive item joined ours automatically, then the merge took both
        #expect(merged?.bundleId == "tivola/webmaster")
        #expect(merged?.ids["lutris"] == "webmaster-fantastic")
    }

    @Test func mergingAgainJoinsOverlappingGroups() {
        var rules = MergeRules()
        rules.merge(["a:1", "b:2"])
        rules.merge(["b:2", "c:3"])
        #expect(rules.groups == [["a:1", "b:2", "c:3"]])
    }

    @Test func separateTakesAHitOutOfItsProgram() {
        var rules = MergeRules()
        #expect(rules.apply([ours, wikidata, archive]).count == 1)
        rules.separate(MergeRules.key(archive))
        let results = rules.apply([ours, wikidata, archive])
        #expect(results.count == 2)
        #expect(results.contains { $0.hits.map(\.sourceId) == ["webmaster2000"] })
    }

    @Test func unmergeUndoesBoth() {
        var rules = MergeRules()
        rules.merge([MergeRules.key(ours), MergeRules.key(lutris)])
        rules.separate(MergeRules.key(archive))
        rules.unmerge([MergeRules.key(lutris), MergeRules.key(archive)])
        #expect(rules == MergeRules())
    }
}

// Two programs that turn out to be one: what each holds ends up in one.
@Suite struct AbsorbTests {
    @Test func picturesDesignsAndPinsMoveAndTheOtherGoes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-absorb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        try await store.saveProgram(.init(slug: "a", title: "Webmaster", ids: ["wikidata": "Q1"], platforms: nil, updated: nil))
        try await store.saveProgram(.init(slug: "b", title: "Webmaster", ids: ["lutris": "webmaster"], platforms: nil, updated: nil))
        let png = root.appendingPathComponent("p.png")
        try Bitmap(width: 4, height: 4, fill: (200, 10, 10, 255)).writePNG(to: png)
        var picked = try await store.addMedia("b", from: png, name: "box.png", source: "Your files")
        picked.picked = true
        try await store.upsertMedia("b", picked)
        _ = try await store.addMedia("a", from: png, name: "box.png", source: "Your files")   // the same picture, unpicked
        try await store.saveDoc("b", id: "d1", json: Data(#"{"id":"d1","program":"b","name":"Lifted"}"#.utf8))
        var st = Store.State(); st.pins = ["d1"]
        try await store.saveState("b", st)

        try await store.absorb("b", into: "a")

        #expect(await store.program("b") == nil)
        #expect(await store.media("a").count == 1)
        let moved = try #require(await store.media("a").first)
        #expect(moved.picked)
        #expect(FileManager.default.fileExists(atPath: store.mediaFile("a", moved.file).path))
        #expect(await store.state("a").pins == ["d1"])
        let doc = try #require(await store.doc("a", "d1"))
        #expect((try JSONSerialization.jsonObject(with: doc) as? [String: Any])?["program"] as? String == "a")
    }
}
