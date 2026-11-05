import Foundation
import Testing
@testable import SCKit
import WrappBuilder

@Suite("Sharded integration runs")
struct ShardedRunTests {
    private typealias Game = ShardPlan.Game
    private typealias Slot = ShardPlan.Slot

    private func game(_ slug: String, _ weight: Int64 = 1, needs: Set<String> = []) -> Game {
        Game(slug: slug, weight: weight, needs: needs)
    }

    private func row(_ slug: String, _ status: String = "passed", source: String = "disk") -> GameBoard.Row {
        GameBoard.Row(source: source, slug: slug, engine: "wine", status: status)
    }

    // MARK: Handing out games

    @Test("Games that need no installers go round-robin when their sizes are the same")
    func roundRobin() {
        let plan = ShardPlan.assign([game("a"), game("b"), game("c"), game("d")],
                                    to: [Slot(name: "one", has: []), Slot(name: "two", has: [])])
        #expect(plan.shards.map { $0.map(\.slug) } == [["a", "c"], ["b", "d"]])
        #expect(plan.unrunnable.isEmpty)
    }

    @Test("The biggest builds go first, each to the least loaded Mac")
    func biggestFirst() {
        let plan = ShardPlan.assign([game("small", 1), game("big", 10), game("medium", 5), game("tiny", 1)],
                                    to: [Slot(name: "one", has: []), Slot(name: "two", has: [])])
        #expect(plan.shards.map { $0.map(\.slug) } == [["big"], ["medium", "small", "tiny"]])
    }

    @Test("A disc game goes only to a Mac with its installers")
    func installersDecide() {
        let slots = [Slot(name: "one", has: ["disk/a"]), Slot(name: "two", has: ["disk/b", "disk/c"])]
        let plan = ShardPlan.assign([game("a", needs: ["disk/a"]), game("b", needs: ["disk/b"]), game("c", needs: ["disk/c"])], to: slots)
        #expect(plan.shards.map { $0.map(\.slug) } == [["a"], ["b", "c"]])
    }

    @Test("A game no Mac can run is reported, not dropped")
    func unrunnable() {
        let plan = ShardPlan.assign([game("a", needs: ["disk/a"]), game("b")], to: [Slot(name: "one", has: [])])
        #expect(plan.shards.map { $0.map(\.slug) } == [["b"]])
        #expect(plan.unrunnable.map(\.slug) == ["a"])
    }

    @Test("Installers only this Mac has go where they'll be sent, but a Mac that has them comes first")
    func sentFromHere() {
        let slots = [Slot(name: "one", has: []), Slot(name: "two", has: ["disk/b"])]
        let plan = ShardPlan.assign([game("a", needs: ["disk/a"]), game("b", needs: ["disk/b"])], to: slots, sentFromHere: ["disk/a", "disk/b"])
        #expect(plan.shards.map { $0.map(\.slug) } == [["a"], ["b"]])
        #expect(plan.unrunnable.isEmpty)
    }

    @Test("With no Mac, every game is unrunnable")
    func noMacs() {
        let plan = ShardPlan.assign([game("a")], to: [])
        #expect(plan.shards.isEmpty)
        #expect(plan.unrunnable.map(\.slug) == ["a"])
    }

    @Test("A store's listing names games whose disc edition is all there, and those with a Her download")
    func installerKeys() {
        let manifests = InstallersStore.manifests(bundles: repoRoot.appendingPathComponent("Bundles"))
        let keys = ShardPlan.installerKeys(listing: [
            "nancy-drew/ghost-dogs/cd/disc-1.iso", "nancy-drew/trail-of-the-twister/cd/disc-1.iso",
            "nancy-drew/scarlet-hand/her-windows/installer.exe", "nancy-drew/scarlet-hand/extras/guide.pdf",
            "nancy-drew/trail-of-the-twister/her-mac/installer.dmg", "loose-file.iso",
        ], manifests: manifests)
        #expect(keys == ["disk/ghost-dogs", "her-download/scarlet-hand", "her-download/trail-of-the-twister"])
    }

    @Test("Only the disc and Her suites need installers")
    func needs() {
        #expect(ShardPlan.needs("x", sources: [.disk, .steam, .herDownload, .download]) == ["disk/x", "her-download/x"])
        #expect(ShardPlan.needs("x", sources: [.download, .bigFishTrial]).isEmpty)
    }

    // MARK: Gathering the results

    @Test("Shards' rows merge in the catalogue's order, each naming its Mac and session")
    func mergeOrder() {
        let outcomes = [
            ShardOutcome(mac: "two", session: "user-b", planned: [row("c")], result: .reported(
                ShardResult(status: 0, rows: [row("c")], failures: [], bundle: nil))),
            ShardOutcome(mac: "one", session: "user-a", planned: [row("a")], result: .reported(
                ShardResult(status: 0, rows: [row("a"), row("a", source: "steam")], failures: [], bundle: nil))),
        ]
        let merged = ShardReport.merge(outcomes, order: ["a", "b", "c"])
        #expect(merged.rows.map { "\($0.mac)/\($0.session) \($0.row.source)/\($0.row.slug)" }
            == ["one/user-a disk/a", "one/user-a steam/a", "two/user-b disk/c"])
        #expect(!merged.failed)
    }

    @Test("A failed game fails the run")
    func testFailure() {
        let outcome = ShardOutcome(mac: "one", session: "s", planned: [row("a")], result: .reported(
            ShardResult(status: 65, rows: [row("a", "failed")], failures: ["a: it quit"], bundle: nil)))
        #expect(ShardReport.merge([outcome], order: ["a"]).failed)
    }

    @Test("A shard that didn't report shows its games as an infrastructure failure, not a test failure")
    func infrastructure() {
        let outcome = ShardOutcome(mac: "one", session: "s", planned: [row("a", "pending"), row("b", "pending")],
                                   result: .infrastructure("lost the connection"))
        let merged = ShardReport.merge([outcome], order: ["a", "b"])
        #expect(merged.rows.map(\.row.status) == [ShardReport.infrastructureStatus, ShardReport.infrastructureStatus])
        #expect(merged.failed)
    }

    @Test("Games no Mac could run are rows of their own, and fail the run")
    func unrunnableRows() {
        let passing = ShardOutcome(mac: "one", session: "s", planned: [row("b")], result: .reported(
            ShardResult(status: 0, rows: [row("b")], failures: [], bundle: nil)))
        let merged = ShardReport.merge([passing], unrunnable: [row("a", "pending")], order: ["a", "b"])
        #expect(merged.rows.map { "\($0.mac):\($0.row.slug):\($0.row.status)" } == [":a:\(ShardReport.unrunnableStatus)", "one:b:passed"])
        #expect(merged.failed)
    }

    @Test("A Her download's Mac row sorts with its game")
    func herMacRow() {
        let outcome = ShardOutcome(mac: "one", session: "s", planned: [], result: .reported(ShardResult(
            status: 0, rows: [row("b", source: "her-download"), row("a mac", source: "her-download"), row("a", source: "her-download")],
            failures: [], bundle: nil)))
        #expect(ShardReport.merge([outcome], order: ["a", "b"]).rows.map(\.row.slug) == ["a", "a mac", "b"])
    }

    @Test("The merged table puts the Mac and session first")
    func table() {
        let rows = [ShardReport.Row(mac: "one", session: "s", row: row("a"))]
        #expect(ShardReport.table(rows, showSource: false).headers.prefix(3) == ["Mac", "Session", "Game"])
    }

    @Test("A shard's result survives the trip as JSON")
    func resultRoundTrip() throws {
        var passed = row("a")
        passed.buildSeconds = 12
        passed.warnings = ["slow"]
        let result = ShardResult(status: 0, rows: [passed], failures: [], bundle: "/x.xcresult")
        let decoded = try JSONDecoder().decode(ShardResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }

    @Test("The claim's JSON line is found among the run's other output")
    func claimLine() {
        #expect(ShardCoordinator.Claim.parse("Claimed host/sctest until 15:00.") == nil)
        let claim = ShardCoordinator.Claim.parse(#"{"expires":"2026-11-05T05:00:00Z","host":"host","user":"sctest"}"# + "\r")
        #expect(claim?.user == "sctest")
        #expect(claim?.expires != nil)
    }

    @Test("--shard-on splits on commas and keeps each Mac's path")
    func parseMacs() {
        #expect(ShardCoordinator.parseMacs("one, two:~/tmp/x,") == ["one", "two:~/tmp/x"])
    }

    @Test("Homebrew's folders join a bare PATH once, after what's there")
    func homebrewPath() {
        #expect(ToolPath.withHomebrew("/usr/bin:/bin") == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(ToolPath.withHomebrew("/opt/homebrew/bin:/usr/bin") == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
    }
}
