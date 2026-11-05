import Testing
import Foundation
import Logging
@testable import SecondChance
@testable import SecondChanceKit
@testable import WineKit
@testable import WrappLogging

@Suite("Failure summary")
struct FailureSummaryTests {

    @Test("The summary names the stage, the error chain and the stage's first error")
    func summary() {
        let underlying = NSError(domain: "Inner", code: 7, userInfo: [NSLocalizedDescriptionKey: "inner thing"])
        let error = NSError(domain: "Outer", code: 1, userInfo: [NSLocalizedDescriptionKey: "outer thing", NSUnderlyingErrorKey: underlying])

        // LogStore is shared by every test in the process, so another test's
        // error (WineNoDisplayTests logs Wine's nodrv line) can land between
        // entering the stage and this test's first error, and be "first".
        // Try again in a fresh stage when that happens.
        var marker = ""
        var text = ""
        for _ in 1...5 {
            marker = UUID().uuidString
            LogContext.enterStage("Stage \(marker)")
            LogStore.shared.append(level: "notice", label: "au.gare.callum.second-chance.Test.X", message: "fine")
            LogStore.shared.append(level: "error", label: "au.gare.callum.second-chance.Test.X", message: "first \(marker)")
            LogStore.shared.append(level: "error", label: "au.gare.callum.second-chance.Test.X", message: "second \(marker)")
            LogStore.shared.append(level: "warning", label: "au.gare.callum.second-chance.Shared.Wine", message: "wine said \(marker)")
            text = FailureSummary.render(what: "Testing", error: error, files: [("Diagnostics", "/tmp/x")])
            if text.contains("first \(marker)") { break }
        }

        #expect(text.hasPrefix(FailureSummary.startMarker))
        #expect(text.hasSuffix(FailureSummary.endMarker))
        #expect(text.contains("What failed: Testing, during \"Stage \(marker)\""))
        #expect(text.contains("Error: outer thing [Outer 1]"))
        #expect(text.contains("caused by: inner thing [Inner 7]"))
        #expect(text.contains("First error in this stage:") && text.contains("first \(marker)"))
        #expect(!text.contains("second \(marker)"))
        #expect(text.contains("wine said \(marker)"))
        #expect(text.contains("Diagnostics: /tmp/x"))
        #expect(text.contains("Load now: "))
        #expect(text.contains("Run: \(RunContext.runID)"))
    }

    @Test("The summary names the programs the stage started and how each ended")
    func programs() {
        let marker = UUID().uuidString
        LogContext.enterStage("Stage \(marker)")
        LogStore.shared.append(level: "notice", label: "au.gare.callum.second-chance.SecondChance.WineProcess",
                               message: "▶ wine reg started (pid 1): reg import \(marker)")
        LogStore.shared.append(level: "error", label: "au.gare.callum.second-chance.SecondChance.WineProcess",
                               message: "■ wine reg (pid 1) was killed by SIGTERM (15) — cancelled \(marker)")
        let text = FailureSummary.render(what: "Testing", error: nil)
        #expect(text.contains("Programs this stage started and ended:"))
        #expect(text.contains("reg import \(marker)"))
        #expect(text.contains("cancelled \(marker)"))
    }

    @Test("Cancelling isn't a failure worth summarising")
    func cancellation() {
        #expect(WrappBuildViewModel.isCancellation(WrappBuildError.userCancelled))
        #expect(!WrappBuildViewModel.isCancellation(WrappBuildError.installerNotFound))
    }
}
