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
    /// The game's Steam app ID, when it is sold (or was) on Steam.
    let steamAppID: Int?
    /// The folder Steam installs it into, under `steamapps/common/`.
    let steamInstallDir: String?
    /// The Windows executable Steam launches, relative to `steamInstallDir`.
    let steamExePath: String?
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

    /// Where a game lives on Steam, from its app info.
    struct SteamApp: Hashable {
        let appID: Int
        let installDir: String
        let exe: String
    }

    /// How a Steam-sourced wrapp starts its game, when the game lets the
    /// user choose (`offersSteamLaunchChoice`).
    enum SteamLaunchMode: String, Codable, CaseIterable {
        /// Through Steam: slower, but Steam Cloud keeps the saves.
        case steam
        /// Without Steam, which is removed from the wrapp: quicker and more
        /// reliable, saves stay on this Mac.
        case direct
    }

    var isOnSteam: Bool { steamAppID != nil }

    /// Only a game known to have no DRM can run without Steam — and the games
    /// ScummVM runs always do (see `steamEngine`), so they offer no choice.
    var offersSteamLaunchChoice: Bool { isOnSteam && steamDRM == .no && gameEngine != .scummvm }

    /// The engine a Steam-sourced wrapp of this game uses.
    ///
    /// A game ScummVM runs from disc runs in ScummVM on Steam's files too,
    /// whatever its DRM: ScummVM reads the data, never the exe, and Steam's
    /// exe under Wine ignores the mouse (its cursor stays put while clicks
    /// land elsewhere). Any other game that needs Steam is launched by Steam
    /// (`-applaunch`), which works whatever its DRM: starting the exe
    /// ourselves with Steam running (`.wineSteamSilent`) left Blue Moon's
    /// Steam release running with no window, though its DRM is meant to need
    /// only Steam running. Only a DRM-free game the user chose to launch
    /// directly runs without Steam.
    func steamEngine(launchMode: SteamLaunchMode?) -> GameEngine {
        if gameEngine == .scummvm { return .scummvm }
        if steamDRM == .no && launchMode == .direct { return gameEngine }
        return .wineSteam
    }
    
    init(
        id: String,
        title: String,
        diskCount: Int = 1,
        gameEngine: GameEngine = .wine,
        internalGameExePath: String? = nil,
        steamDRM: SteamDRM? = nil,
        steam: SteamApp? = nil,
        doesNotExitInNonInteractiveMode: Bool = false,
        installInstructions: String? = nil,
        failedInstallInfo: String? = nil
    ) {
        self.id = id
        self.title = title
        self.diskCount = diskCount
        self.gameEngine = gameEngine
        self.steamDRM = steamDRM
        self.steamAppID = steam?.appID
        self.steamInstallDir = steam?.installDir
        self.steamExePath = steam?.exe
        self.internalGameExePath = internalGameExePath
        self.doesNotExitInNonInteractiveMode = doesNotExitInNonInteractiveMode
        self.installInstructions = installInstructions
        self.failedInstallInfo = failedInstallInfo
    }
}
extension GameInfo {
    /// What to tell someone clicking through a game's installer themselves,
    /// for a game with no instructions of its own.
    static let defaultInstallInstructions = """
    Accept the options it suggests, with two exceptions: if it offers to install DirectX, \
    choose not to, and if it asks whether to play the game when it's done, choose No.
    """

    static let unknownGame = GameInfo(
        id: "unknown",
        title: "Other",
        installInstructions: defaultInstallInstructions
    )
}
