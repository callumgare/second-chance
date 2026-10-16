import Testing
import Foundation
import Logging
@testable import SecondChance

@Suite("Failure summary")
struct FailureSummaryTests {

    @Test("The summary names the stage, the error chain and the stage's first error")
    func summary() {
        let marker = UUID().uuidString
        LogContext.enterStage("Stage \(marker)")
        LogStore.shared.append(level: "notice", label: "au.gare.callum.second-chance.Test.X", message: "fine")
        LogStore.shared.append(level: "error", label: "au.gare.callum.second-chance.Test.X", message: "first \(marker)")
        LogStore.shared.append(level: "error", label: "au.gare.callum.second-chance.Test.X", message: "second \(marker)")
        LogStore.shared.append(level: "warning", label: "au.gare.callum.second-chance.Shared.Wine", message: "wine said \(marker)")

        let underlying = NSError(domain: "Inner", code: 7, userInfo: [NSLocalizedDescriptionKey: "inner thing"])
        let error = NSError(domain: "Outer", code: 1, userInfo: [NSLocalizedDescriptionKey: "outer thing", NSUnderlyingErrorKey: underlying])
        let text = FailureSummary.render(what: "Testing", error: error, files: [("Diagnostics", "/tmp/x")])

        #expect(text.hasPrefix(FailureSummary.startMarker))
        #expect(text.hasSuffix(FailureSummary.endMarker))
        #expect(text.contains("What failed: Testing, during \"Stage \(marker)\""))
        #expect(text.contains("outer thing"))
        #expect(text.contains("caused by: inner thing [Inner 7]"))
        #expect(text.contains("First error in this stage:") && text.contains("first \(marker)"))
        #expect(!text.contains("second \(marker)"))
        #expect(text.contains("wine said \(marker)"))
        #expect(text.contains("Diagnostics: /tmp/x"))
        #expect(text.contains("Run: \(RunContext.runID)"))
    }

    @Test("Cancelling isn't a failure worth summarising")
    func cancellation() {
        #expect(WrappBuildViewModel.isCancellation(WrappBuildError.userCancelled))
        #expect(!WrappBuildViewModel.isCancellation(WrappBuildError.installerNotFound))
    }
}
