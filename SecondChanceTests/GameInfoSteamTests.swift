//
//  GameInfoSteamTests.swift
//  SecondChanceTests
//
//  Each game's Steam data, and how its Steam edition starts it.

import Foundation
import Testing
@testable import SecondChance
import GameCatalog
import WrappBuilder
import WrappFormat
import WrappModules

@Suite("Game info: Steam")
struct GameInfoSteamTests {
    let games = GameInfoProvider.shared.allGames()

    @Test("Steam data is complete and the app IDs are unique")
    func steamDataIsWhole() {
        let onSteam = games.filter(\.isOnSteam)
        #expect(onSteam.count >= 30)
        for game in onSteam {
            #expect(game.steamInstallDir?.isEmpty == false, "\(game.id) has no install dir")
            // The program Steam starts, from the edition's launch; ScummVM reads data, and has none.
            if game.gameEngine == .scummvm {
                #expect(game.steamExePath == nil, "\(game.id)'s exe is \(game.steamExePath ?? "nil")")
            } else {
                #expect(game.steamExePath?.lowercased().hasSuffix(".exe") == true, "\(game.id)'s exe is \(game.steamExePath ?? "nil")")
            }
        }
        let ids = onSteam.compactMap(\.steamAppID)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Only a game whose Steam edition has a launch-mode input offers the launch choice")
    func launchChoice() throws {
        let byID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        #expect(try !#require(byID["haunted-mansion"]).offersSteamLaunchChoice)  // DRM-free, but always ScummVM
        #expect(try #require(byID["shadow-ranch"]).offersSteamLaunchChoice)  // DRM-free
        #expect(try !#require(byID["blue-moon"]).offersSteamLaunchChoice)  // DRM
        #expect(try !#require(byID["sea-of-darkness"]).offersSteamLaunchChoice)  // not worked out
        #expect(try !#require(byID["stay-tuned"]).offersSteamLaunchChoice)  // not on Steam
    }

    @Test("A Steam edition's plan says how it starts: through Steam, by Wine when chosen, or ScummVM", arguments: [
        // (game, choice, expected)
        ("thornton-hall", nil, GameInfo.GameEngine.wineSteam),
        ("blue-moon", nil, .wineSteam),
        ("shadow-ranch", "steam", .wineSteam),
        ("shadow-ranch", "direct", .wine),
        ("royal-tower", nil, .scummvm),
        ("sea-of-darkness", nil, .wineSteam),
    ] as [(String, String?, GameInfo.GameEngine)])
    func engine(game: String, choice: String?, expected: GameInfo.GameEngine) throws {
        let plan = try ShippedBundles.plan(forGame: game, edition: "steam", choices: choice.map { ["launch-mode": $0] } ?? [:])
        let launch = try #require(plan?.launch)
        #expect(SteamWrappBuilder.composition(of: launch).legacyEngine == expected)
        // Only a game started by Steam with a choice can fall back to Wine.
        #expect((launch.fallback != nil) == (choice == "steam"))
    }

    @Test("What each engine needs to start a game", arguments: [
        (GameInfo.GameEngine.wine, true, false, false),
        (.wineSteamSilent, true, true, false),
        (.wineSteam, true, true, true),
        (.scummvm, false, false, false),
    ])
    func engineNeeds(engine: GameInfo.GameEngine, wine: Bool, steam: Bool, launchedBySteam: Bool) {
        #expect(engine.runsInWine == wine)
        #expect(engine.needsSteam == steam)
        #expect(engine.launchedBySteam == launchedBySteam)
    }
}
