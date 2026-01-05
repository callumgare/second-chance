//
//  GameInfo.swift
//  SecondChance
//
//  Model representing a Nancy Drew game with all its metadata

import Foundation

/// Represents a Nancy Drew game with all its metadata and installation requirements
struct GameInfo: Codable, Identifiable, Hashable {
    let id: String  // Game slug
    let title: String
    let diskCount: Int
    let gameEngine: GameEngine
    let steamDRM: SteamDRM?
    let steamID: String?
    let internalGameExePath: String?
    let doesNotExitInNonInteractiveMode: Bool
    let installInstructions: String?
    let failedInstallInfo: String?
    
    enum GameEngine: String, Codable {
        case wine
        case scummvm
        case wineSteam = "wine-steam"
        case wineSteamSilent = "wine-steam-silent"
    }
    
    enum SteamDRM: String, Codable {
        case no
        case yesLaunchWhenSteamRunning = "yes-launch-when-steam-running"
        case yesLaunchViaSteamOnly = "yes-launch-via-steam-only"
    }
    
    init(
        id: String,
        title: String,
        diskCount: Int = 1,
        gameEngine: GameEngine = .wine,
        internalGameExePath: String? = nil,
        steamDRM: SteamDRM? = nil,
        steamID: String? = nil,
        doesNotExitInNonInteractiveMode: Bool = false,
        installInstructions: String? = nil,
        failedInstallInfo: String? = nil
    ) {
        self.id = id
        self.title = title
        self.diskCount = diskCount
        self.gameEngine = gameEngine
        self.steamDRM = steamDRM
        self.steamID = steamID
        self.internalGameExePath = internalGameExePath
        self.doesNotExitInNonInteractiveMode = doesNotExitInNonInteractiveMode
        self.installInstructions = installInstructions
        self.failedInstallInfo = failedInstallInfo
    }
}
extension GameInfo {
    static let unknownGame = GameInfo(
        id: "unknown",
        title: "Other",
        installInstructions: """
        - Accept all default options unless the installer tries to install DirectX. \
        In which case select the option NOT to install DirectX. \
        If asked if you want to play the game after installation, select "No".
        """
    )
}
