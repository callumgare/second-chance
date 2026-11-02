import Foundation
import GameCatalog
import Testing
@testable import WrappModules

struct CompositionTests {
    @Test("Each of today's engines is a composition, and reads back as that engine",
          arguments: GameInfo.GameEngine.allCases)
    func legacyEnginesRoundTrip(_ engine: GameInfo.GameEngine) {
        let composition = Composition(legacy: engine)
        #expect(composition.legacyEngine == engine)
        #expect(composition.engineTag == engine.rawValue)
    }

    @Test("A composition has a module where the engine said so")
    func hasMatchesTheEngineQuestions() {
        for engine in GameInfo.GameEngine.allCases {
            let composition = Composition(legacy: engine)
            #expect(composition.has(.wine) == engine.runsInWine, "\(engine)")
            #expect(composition.has(.steam) == engine.needsSteam, "\(engine)")
            #expect((composition.launcher == .steam) == engine.launchedBySteam, "\(engine)")
            #expect((composition.launcher == .scummvm) == (engine == .scummvm), "\(engine)")
        }
    }

    @Test("Steam brings Wine, before itself, once")
    func dependenciesComeFirstAndOnce() {
        #expect(Composition(launcher: .steam, services: [.steam]).modules == [.wine, .steam])
        #expect(Composition(launcher: .wine, services: [.steam]).modules == [.wine, .steam])
    }

    @Test("A composition no engine expresses is tagged by its launcher")
    func newCompositionsAreTaggedByLauncher() {
        let composition = Composition(launcher: "dosbox")
        #expect(composition.legacyEngine == nil)
        #expect(composition.engineTag == "dosbox")
    }

    @Test("A module id is written as its name")
    func idsEncodeAsText() throws {
        let data = try JSONEncoder().encode(Composition(launcher: .wine, services: [.steam]))
        #expect(String(decoding: data, as: UTF8.self).contains("\"launcher\":\"wine\""))
        #expect(try JSONDecoder().decode(Composition.self, from: data) == Composition(launcher: .wine, services: [.steam]))
    }
}
