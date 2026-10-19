import Testing
@testable import SecondChance

@Suite("Wrapp loading stages")
struct LoadingStageTests {
    static let timed: [LoadingStage] = [
        .startingGame(title: "Danger by Design"),
        .startingSteam,
        .steamStartingGame(title: "Curse of Blackmoor Manor"),
    ]

    @Test("A stage says it's slow before it says it may have failed", arguments: timed)
    func slowBeforeFailure(stage: LoadingStage) throws {
        let slow = try #require(stage.slowNoteAfter)
        let failure = try #require(stage.possibleFailureAfter)
        #expect(slow < failure)
    }

    @Test("Steam gets far longer than the game started directly")
    func steamWaitsLonger() throws {
        let direct = LoadingStage.startingGame(title: "x")
        for stage in [LoadingStage.startingSteam, .steamStartingGame(title: "x")] {
            #expect(try #require(stage.slowNoteAfter) >= 3 * #require(direct.slowNoteAfter))
            #expect(try #require(stage.possibleFailureAfter) >= 5 * #require(direct.possibleFailureAfter))
        }
    }

    @Test("Waiting for the player to sign in to Steam never counts as slow")
    func signInHasNoClock() {
        #expect(LoadingStage.signingInToSteam.slowNoteAfter == nil)
        #expect(LoadingStage.signingInToSteam.possibleFailureAfter == nil)
    }

    @Test("Each stage names what's loading")
    func namesWhatsLoading() {
        #expect(LoadingStage.startingSteam.message.contains("Steam"))
        #expect(LoadingStage.startingSteam.subject == "Steam")
        #expect(LoadingStage.steamStartingGame(title: "Old Clock").message.contains("Steam is starting Old Clock"))
        #expect(LoadingStage.steamStartingGame(title: "Old Clock").subject == "The game")
        #expect(LoadingStage.startingGame(title: "Old Clock").message.contains("Old Clock"))
    }
}
