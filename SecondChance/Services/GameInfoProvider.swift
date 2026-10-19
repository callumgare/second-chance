//
//  GameInfoProvider.swift
//  SecondChance
//
//  Provides game metadata for all Nancy Drew titles

import Foundation

/// Provides game information for all supported Nancy Drew titles
class GameInfoProvider {
    static let shared = GameInfoProvider()
    
    private init() {}
    
    /// All known Nancy Drew games with their metadata, in chronological order
    private lazy var gamesList: [GameInfo] = [
        GameInfo(
            id: "secrets-can-kill",
            title: "Secrets Can Kill",
            diskCount: 2,
            gameEngine: .scummvm
        ),
        GameInfo(
            id: "secrets-can-kill-remastered",
            title: "Secrets Can Kill Remastered",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Nancy Drew SCK/Secrets.exe",
            steam: .init(appID: 42210, installDir: "Nancy Drew Secrets Can Kill", exe: "Secrets.exe")
        ),
        GameInfo(
            id: "stay-tuned",
            title: "Stay Tuned for Danger",
            diskCount: 1,
            gameEngine: .scummvm
        ),
        GameInfo(
            id: "haunted-mansion",
            title: "Message in a Haunted Mansion",
            diskCount: 1,
            gameEngine: .scummvm,
            steamDRM: .no,
            steam: .init(appID: 615770, installDir: "Nancy Drew Message in a Haunted Mansion", exe: "Game.exe")
        ),
        GameInfo(
            id: "royal-tower",
            title: "Treasure in the Royal Tower",
            diskCount: 1,
            gameEngine: .scummvm,
            steamDRM: .no,
            steam: .init(appID: 615780, installDir: "Nancy Drew Treasure in the Royal Tower", exe: "game.exe")
        ),
        GameInfo(
            id: "final-scene",
            title: "The Final Scene",
            diskCount: 1,
            gameEngine: .scummvm,
            steam: .init(appID: 615730, installDir: "Nancy Drew The Final Scene", exe: "Game.exe")
        ),
        GameInfo(
            id: "scarlet-hand",
            title: "Secret of the Scarlet Hand",
            diskCount: 1,
            gameEngine: .scummvm,
            steam: .init(appID: 31890, installDir: "Nancy Drew Secret of the Scarlet Hand", exe: "Game.exe")
        ),
        GameInfo(
            id: "ghost-dogs",
            title: "Ghost Dogs of Moon Lake",
            diskCount: 1,
            gameEngine: .scummvm,
            steam: .init(appID: 31850, installDir: "Nancy Drew Ghost Dogs of Moon Lake", exe: "Game.exe")
        ),
        GameInfo(
            id: "haunted-carousel",
            title: "The Haunted Carousel",
            diskCount: 1,
            internalGameExePath: "/Nancy Drew/The Haunted Carousel/Game.exe",
            steam: .init(appID: 31820, installDir: "Nancy Drew The Haunted Carousel", exe: "Game.exe"),
            doesNotExitInNonInteractiveMode: true
        ),
        GameInfo(
            id: "deception-island",
            title: "Danger on Deception Island",
            diskCount: 1,
            internalGameExePath: "/Nancy Drew/Danger on Deception Island/Game.exe",
            steam: .init(appID: 31840, installDir: "Nancy Drew Danger on Deception Island", exe: "Game.exe"),
            doesNotExitInNonInteractiveMode: true
        ),
        GameInfo(
            id: "shadow-ranch",
            title: "The Secret of Shadow Ranch",
            diskCount: 1,
            internalGameExePath: "/Nancy Drew/Secret of Shadow Ranch/Game.exe",
            steamDRM: .no,
            steam: .init(appID: 572740, installDir: "Nancy Drew The Secret of Shadow Ranch", exe: "Game.exe"),
            doesNotExitInNonInteractiveMode: true
        ),
        GameInfo(
            id: "blackmoor-manor",
            title: "Curse of Blackmoor Manor",
            diskCount: 1,
            internalGameExePath: "/Nancy Drew/The Curse of Blackmoor Manor/Game.exe",
            steamDRM: .yesLaunchWhenSteamRunning,
            steam: .init(appID: 31830, installDir: "Nancy Drew Curse of Blackmoor Manor", exe: "Game.exe"),
            doesNotExitInNonInteractiveMode: true
        ),
        GameInfo(
            id: "old-clock",
            title: "Secret of the Old Clock",
            diskCount: 1,
            internalGameExePath: "/Nancy Drew/Secret of the Old Clock/Game.exe",
            steamDRM: .no,
            steam: .init(appID: 31880, installDir: "Nancy Drew Secret of the Old Clock", exe: "Game.exe"),
            doesNotExitInNonInteractiveMode: true
        ),
        GameInfo(
            id: "blue-moon",
            title: "Last Train to Blue Moon Canyon",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon/Game.exe",
            steamDRM: .yesLaunchWhenSteamRunning,
            steam: .init(appID: 31810, installDir: "Nancy Drew Last Train to Blue Moon Canyon", exe: "Game.exe")
        ),
        GameInfo(
            id: "danger-by-design",
            title: "Danger by Design",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Danger by Design/Game.exe",
            steam: .init(appID: 31800, installDir: "Nancy Drew Danger by Design", exe: "Game.exe")
        ),
        GameInfo(
            id: "kapu-cave",
            title: "The Creature of Kapu Cave",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/The Creature of Kapu Cave/Game.exe",
            steam: .init(appID: 31900, installDir: "Nancy Drew The Creature of Kapu Cave", exe: "Game.exe")
        ),
        GameInfo(
            id: "white-wolf",
            title: "The White Wolf of Icicle Creek",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/The White Wolf of Icicle Creek/Game.exe",
            steam: .init(appID: 31930, installDir: "Nancy Drew - The White Wolf of Icicle Creek", exe: "Game.exe")
        ),
        GameInfo(
            id: "crystal-skull",
            title: "Legend of the Crystal Skull",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Legend of the Crystal Skull/Game.exe",
            steam: .init(appID: 31860, installDir: "Nancy Drew Legend of The Crystal Skull", exe: "Game.exe")
        ),
        GameInfo(
            id: "phantom-of-venice",
            title: "The Phantom of Venice",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/The Phantom of Venice/PhantomOfVenice.exe",
            steam: .init(appID: 31920, installDir: "Nancy Drew The Phantom of Venice", exe: "PhantomOfVenice.exe")
        ),
        GameInfo(
            id: "castle-malloy",
            title: "The Haunting of Castle Malloy",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/The Haunting of Castle Malloy/CastleMalloy.exe",
            steam: .init(appID: 31910, installDir: "Nancy Drew The Haunting of Castle Malloy", exe: "CastleMalloy.exe")
        ),
        GameInfo(
            id: "seven-ships",
            title: "Ransom of the Seven Ships",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Ransom of the Seven Ships/Ransom.exe",
            steam: .init(appID: 31980, installDir: "Nancy Drew Ransom of the Seven Ships", exe: "Ransom.exe")
        ),
        GameInfo(
            id: "waverly-academy",
            title: "Warnings at Waverly Academy",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Warnings at Waverly Academy/Waverly.exe",
            steamDRM: .yesLaunchWhenSteamRunning,
            steam: .init(appID: 43600, installDir: "Nancy Drew Warnings at Waverly Academy", exe: "Waverly.exe")
        ),
        GameInfo(
            id: "trail-of-the-twister",
            title: "Trail of the Twister",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Trail of the Twister/Twister.exe",
            steam: .init(appID: 42230, installDir: "Nancy Drew Trail of the Twister", exe: "Twister.exe")
        ),
        GameInfo(
            id: "waters-edge",
            title: "Shadow at the Water's Edge",
            diskCount: 2,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/Shadow at the Water's Edge/Shadow.exe",
            steamDRM: .yesLaunchWhenSteamRunning,
            steam: .init(appID: 200080, installDir: "Nancy Drew - Shadow Waters Edge", exe: "Shadow.exe")
        ),
        GameInfo(
            id: "captive-curse",
            title: "The Captive Curse",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Nancy Drew/The Captive Curse/Captive.exe",
            steam: .init(appID: 42220, installDir: "Nancy Drew The Captive Curse", exe: "Captive.exe")
        ),
        GameInfo(
            id: "alibi-in-ashes",
            title: "Alibi in Ashes",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/Nancy Drew Alibi in Ashes/Alibi.exe",
            steam: .init(appID: 202670, installDir: "Nancy Drew Alibi in Ashes", exe: "Alibi.exe")
        ),
        GameInfo(
            id: "lost-queen",
            title: "Tomb of the Lost Queen",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/Tomb of the Lost Queen/Tomb.exe",
            steam: .init(appID: 210230, installDir: "Nancy Drew - Tomb of the Lost Queen", exe: "Tomb.exe")
        ),
        GameInfo(
            id: "deadly-device",
            title: "The Deadly Device",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/The Deadly Device/DeadlyDevice.exe",
            steam: .init(appID: 220420, installDir: "Nancy Drew - TheDeadlyDevice", exe: "DeadlyDevice.exe")
        ),
        GameInfo(
            id: "thornton-hall",
            title: "Ghost of Thornton Hall",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/Ghost of Thornton Hall/Thornton.exe",
            steamDRM: .yesLaunchViaSteamOnly,
            steam: .init(appID: 226820, installDir: "Nancy Drew The Ghost of Thornton Hall", exe: "Thornton.exe")
        ),
        GameInfo(
            id: "silent-spy",
            title: "The Silent Spy",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/The Silent Spy/Spy.exe",
            steam: .init(appID: 572730, installDir: "Nancy Drew The Silent Spy", exe: "Spy.exe")
        ),
        GameInfo(
            id: "shattered-medallion",
            title: "The Shattered Medallion",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/The Shattered Medallion/Medallion.exe",
            steam: .init(appID: 572720, installDir: "Nancy Drew The Shattered Medallion", exe: "Medallion.exe")
        ),
        GameInfo(
            id: "labyrinth-of-lies",
            title: "Labyrinth of Lies",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/Labyrinth of Lies/Labyrinth.exe",
            steam: .init(appID: 572710, installDir: "Nancy Drew Labyrinth of Lies", exe: "Labyrinth.exe")
        ),
        GameInfo(
            id: "sea-of-darkness",
            title: "Sea of Darkness",
            diskCount: 1,
            internalGameExePath: "/Program Files (x86)/Her Interactive/Sea of Darkness/SeaOfDarkness.exe",
            steam: .init(appID: 572700, installDir: "Nancy Drew The Sea of Darkness", exe: "SeaOfDarkness.exe")
        )
    ]
    
    /// Dictionary for fast lookup by slug
    private lazy var games: [String: GameInfo] = {
        Dictionary(uniqueKeysWithValues: gamesList.map { ($0.id, $0) })
    }()
    
    /// Retrieve game information by slug
    func gameInfo(for slug: String) -> GameInfo {
        return games[slug] ?? GameInfo.unknownGame
    }
    
    /// Get all known games in their canonical order
    func allGames() -> [GameInfo] {
        return gamesList
    }
}
