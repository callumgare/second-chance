import Foundation
import Testing
@testable import WrappBuilderTool

/// What the engine download check says went wrong, and what to do about it.
struct EngineSourcesTests {
    private func problem(_ kind: EngineSources.Kind, source: String = "s") -> EngineSources.Problem {
        EngineSources.Problem(module: "m", version: "1", source: source, url: "https://example.com/f", kind: kind, reason: "r")
    }

    @Test(arguments: [
        (404, EngineSources.Kind.gone), (410, .gone), (401, .refused), (403, .refused),
        (429, .serverTrouble), (503, .serverTrouble), (302, .unexpected), (0, .unexpected),
    ])
    func statusesHaveTheirKind(status: Int, kind: EngineSources.Kind) {
        #expect(EngineSources.kind(ofStatus: status) == kind)
    }

    @Test func aRefusalIsNotCalledMoved() {
        #expect(EngineSources.reason(forStatus: 401).contains("refused"))
        #expect(EngineSources.summary([problem(.refused)]) == "an engine's download couldn't be checked.")
        #expect(!EngineSources.advice([problem(.refused)]).contains { $0.contains("where it is now") })
    }

    @Test func goneDownloadsAreMoved() {
        #expect(EngineSources.summary([problem(.gone)]) == "an engine's download isn't where its module says.")
        #expect(EngineSources.summary([problem(.gone), problem(.changed)]) == "2 engine downloads aren't where their modules say.")
        #expect(EngineSources.summary([problem(.gone), problem(.unreachable)]) == "2 engine downloads couldn't be checked.")
    }

    @Test func adviceIsGivenOncePerKind() {
        let advice = EngineSources.advice([problem(.refused, source: "a"), problem(.refused, source: "b"), problem(.gone)])
        #expect(advice == [EngineSources.Kind.gone.advice, EngineSources.Kind.refused.advice])
    }
}
