import Foundation
import Testing
@testable import SecondChance
import WrappBuilder

/// The runner's events as the build's: Second Chance's `EMIT` strings as its
/// progress screen's phase and substep, a phase never going back, and the
/// phase an instruction reaches when none is emitted.
struct BuildEventTranslatorTests {
    private func started(_ instruction: String, module: String? = nil) -> BuildEvent {
        .stepStarted(StepRef(stage: "x", index: 0, step: PlannedStep(instruction: instruction, module: module, options: [:], arguments: [],
                                                                      name: nil, origin: "Wrappfile:1")))
    }

    private func states(_ events: [BuildEvent]) -> [WrappBuildState] {
        let translator = BuildEventTranslator()
        return events.flatMap(translator.translate).compactMap { event in
            if case .progress(let state) = event { state } else { nil }
        }
    }

    @Test("A phase emitted is reached, and an earlier one emitted after it is ignored")
    func phasesNeverGoBack() {
        #expect(states([.emitted("second-chance.phase.installing-game"), .emitted("second-chance.phase.setting-up"),
                        .emitted("second-chance.phase.configuring")])
                == [.installingGame(substep: nil), .configuringWrapp(substep: nil)])
    }

    @Test("Without an EMIT, an install reaches installing-game, and the discs copying-installer")
    func instructionsReachTheirPhase() {
        #expect(states([started("KEEP-DISCS", module: "wine"), started("RUN", module: "installer"), started("KEEP-DISCS", module: "wine")])
                == [.copyingInstaller(substep: nil), .installingGame(substep: nil)])
    }

    @Test("A substep emitted is the next step's, in Second Chance's own words")
    func substepsApplyToTheNextStep() {
        #expect(states([.emitted("second-chance.phase.setting-up"), .emitted("second-chance.substep.display"), started("REGISTRY", module: "wine")])
                == [.settingUpWrapp(substep: nil), .settingUpWrapp(substep: WineManager.progressText("display"))])
    }

    @Test("Every string is passed on as it was, and another caller's means nothing here")
    func everyStringIsPassedOn() {
        let translated = BuildEventTranslator().translate(.emitted("someone-else.thing")).map { "\($0)" }
        #expect(translated == ["\(WrappBuildEvent.emitted("someone-else.thing"))"])
    }

    @Test("Every substep key Second Chance reads has its text")
    func everySubstepHasText() {
        for key in SecondChanceEmits.substeps {
            #expect(WineManager.progressText(key) != nil, "\(key)")
        }
    }
}
