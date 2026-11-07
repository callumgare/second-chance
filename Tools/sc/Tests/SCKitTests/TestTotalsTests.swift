import Foundation
import Testing
@testable import SCKit

struct TestTotalsTests {
    private func summary(passed: Int) throws -> TestReports.Summary {
        try JSONDecoder().decode(TestReports.Summary.self, from: Data(#"{"passedTests":\#(passed),"failedTests":0,"skippedTests":0}"#.utf8))
    }

    private func row(_ slug: String, _ status: String) -> GameBoard.Row {
        GameBoard.Row(source: "disk", slug: slug, engine: "wine", status: status)
    }

    @Test("An integration run counts its games, not the result bundle's test functions")
    func integrationCountsGames() throws {
        // Three games, all passed: the bundle says 2 (the slug check and the
        // one parameterized test).
        var run = TestRun(name: "Integration", status: 0, bundle: URL(fileURLWithPath: "/x.xcresult"), summary: try summary(passed: 2))
        run.games = [row("bioscopia", "passed"), row("white-wolf", "passed"), row("danger-by-design", "passed")]
        #expect(TestCommandSupport.total(run) == "Integration: 3 of 3 games passed")
    }

    @Test("Failed, skipped and unrun games are each counted")
    func integrationCountsEachOutcome() {
        var run = TestRun(name: "Integration", status: 1, bundle: URL(fileURLWithPath: "/x.xcresult"), summary: nil)
        run.games = [row("a", "passed"), row("b", "failed"), row("c", "skipped"), row("d", "pending"), row("e", "infrastructure")]
        #expect(TestCommandSupport.total(run) == "Integration: 1 of 5 games passed, 2 failed, 1 skipped, 1 not run")
        run.games = [row("a", "passed")]
        #expect(TestCommandSupport.total(run) == "Integration: 1 of 1 game passed")
    }

    @Test("A unit run still counts its tests")
    func unitCountsTests() throws {
        let run = TestRun(name: "Unit", status: 0, bundle: URL(fileURLWithPath: "/x.xcresult"), summary: try summary(passed: 423))
        #expect(TestCommandSupport.total(run) == "Unit: 423 passed")
    }
}
