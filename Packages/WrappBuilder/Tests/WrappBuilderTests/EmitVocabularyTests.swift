import Foundation
import Testing
@testable import WrappBuilder

/// A caller's `EMIT` vocabulary, checked against a plan.
struct EmitVocabularyTests {
    @Test("A typo, an unknown value and a phase going back are each refused")
    func refuses() {
        let vocabulary = EmitVocabulary(prefix: "sc.", strings: [
            .init(pattern: "sc.phase.<phase>", values: ["phase": .oneOf(["a", "b"])], ordered: "phase"),
            .init(pattern: "sc.progress.<done>/<total>", values: ["done": .number, "total": .number], ordered: nil),
        ])
        let stage = PlannedStage(name: "x", from: .scratch, modules: [], steps: [], emits: [
            "sc.phase.b", "sc.phase.a", "sc.phse.a", "sc.phase.c", "sc.progress.1/2", "sc.progress.x/2", "someone-else.thing",
        ].enumerated().map { PlannedEmit(before: 0, text: $0.element, origin: "Wrappfile:\($0.offset)") })
        #expect(vocabulary.problems(in: BuildPlan(edition: "e", stages: [stage])) == [
            "Wrappfile:1: EMIT \"sc.phase.a\" goes back to a, after b",
            "Wrappfile:2: EMIT \"sc.phse.a\" isn't one of the sc. strings",
            "Wrappfile:3: EMIT \"sc.phase.c\" isn't one of the sc. strings",
            "Wrappfile:5: EMIT \"sc.progress.x/2\" isn't one of the sc. strings",
        ])
    }
}
