//
//  GameInfoSteamTests.swift
//  SecondChanceTests
//
//  Each game's Steam data, and which engine a Steam-sourced wrapp uses.

import Foundation
import Testing
@testable import SecondChance

@Suite("Game info: Steam")
struct GameInfoSteamTests {
    let games = GameInfoProvider.shared.allGames()

    @Test("Every game with known Steam DRM has its Steam app data")
    func drmGamesAreOnSteam() {
        for game in games where game.steamDRM != nil {
            #expect(game.isOnSteam, "\(game.id) has steamDRM but no Steam app")
        }
    }

    @Test("Steam data is complete and the app IDs are unique")
    func steamDataIsWhole() {
        let onSteam = games.filter(\.isOnSteam)
        #expect(onSteam.count >= 30)
        for game in onSteam {
            #expect(game.steamInstallDir?.isEmpty == false, "\(game.id) has no install dir")
            #expect(game.steamExePath?.lowercased().hasSuffix(".exe") == true, "\(game.id)'s exe is \(game.steamExePath ?? "nil")")
        }
        let ids = onSteam.compactMap(\.steamAppID)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Only a game known to be DRM-free offers the launch choice")
    func launchChoice() throws {
        let byID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        #expect(try #require(byID["haunted-mansion"]).offersSteamLaunchChoice)  // .no
        #expect(try #require(byID["shadow-ranch"]).offersSteamLaunchChoice)  // .no
        #expect(try !#require(byID["blue-moon"]).offersSteamLaunchChoice)  // DRM
        #expect(try !#require(byID["sea-of-darkness"]).offersSteamLaunchChoice)  // not worked out
        #expect(try !#require(byID["stay-tuned"]).offersSteamLaunchChoice)  // not on Steam
    }

    @Test("The engine follows the DRM and, for DRM-free games, the user's choice", arguments: [
        // (DRM, disc engine, choice, expected)
        (GameInfo.SteamDRM?.some(.yesLaunchViaSteamOnly), GameInfo.GameEngine.wine, GameInfo.SteamLaunchMode?.none, GameInfo.GameEngine.wineSteam),
        (.yesLaunchWhenSteamRunning, .wine, nil, .wineSteamSilent),
        (.no, .wine, .steam, .wineSteamSilent),
        (.no, .wine, .direct, .wine),
        (.no, .scummvm, .direct, .scummvm),
        (.no, .scummvm, .steam, .wineSteamSilent),
        (.no, .wine, nil, .wineSteamSilent),
        // DRM not worked out: through Steam, which works whatever it is.
        (nil, .wine, nil, .wineSteam),
        (nil, .scummvm, .direct, .wineSteam),
    ])
    func engine(drm: GameInfo.SteamDRM?, disc: GameInfo.GameEngine, choice: GameInfo.SteamLaunchMode?, expected: GameInfo.GameEngine) {
        let game = GameInfo(id: "x", title: "X", gameEngine: disc, steamDRM: drm,
                            steam: .init(appID: 1, installDir: "X", exe: "Game.exe"))
        #expect(game.steamEngine(launchMode: choice) == expected)
    }
}
