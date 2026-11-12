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
