//
//  GameInfo.swift
//  GameCatalog
//
//  Model representing a Nancy Drew game with all its metadata

import Foundation

/// Represents a Nancy Drew game with all its metadata and installation requirements
public nonisolated struct GameInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String  // Game slug
    public let title: String
    public let diskCount: Int
    public let gameEngine: GameEngine
    /// What a Wine game draws with, as its .exe's imports said in the
    /// editions we could read. A wrapp goes by the .exe it has, and by this
    /// only when the .exe can't say: Armadillo hides the imports of every
    /// Big Fish edition (`GameGraphicsAPI`).
    public let graphics: Graphics?
    public let steamDRM: SteamDRM?
    /// The game's Steam app ID, when it is sold (or was) on Steam.
    public let steamAppID: Int?
    /// The folder Steam installs it into, under `steamapps/common/`.
    public let steamInstallDir: String?
    /// The Windows executable Steam launches, relative to `steamInstallDir`.
    public let steamExePath: String?
    /// The game's product number on Big Fish Games, the number in each of its
    /// SKUs (`F2435T1L1`: product 2435, English). One for every language
    /// edition it's sold in.
    public let bigFishProduct: Int?
    public let internalGameExePath: String?
    public let installInstructions: String?
    public let failedInstallInfo: String?
    /// Other names a disc or download calls the game by, besides its title,
    /// matched as the title is: case aside, anywhere in its fingerprint.
    public let detectionAliases: [String]
    /// Short codes a disc calls it by ("STFD"), matched in capitals, as a
    /// whole word: in lower case they could be anything.
    public let detectionCodes: [String]
    /// Its bundle's id when that isn't `nancy-drew/<id>`: a program beyond
    /// Nancy Drew (`freeware/skifree`).
    public let program: String?
    /// What its app is called, when that isn't "Nancy Drew - <title>".
    public let displayName: String?

    /// Its program bundle's id: `nancy-drew/blue-moon`.
    public var programID: String { program ?? "nancy-drew/\(id)" }

    /// The name of the game's app, as Finder and the Dock show it.
    public var appName: String { displayName ?? "Nancy Drew - \(title)" }
    /// The game's app's file name.
    public var appBundleName: String { appName + ".app" }

    public enum GameEngine: String, Codable, Sendable, CaseIterable {
        case wine
        case scummvm
        case wineSteam = "wine-steam"
        case wineSteamSilent = "wine-steam-silent"
        case dosbox

        /// Wine runs the game: every engine but ScummVM and DOSBox.
        public var runsInWine: Bool { self != .scummvm && self != .dosbox }

        /// Steam has to be running, and signed in, before the game starts.
        public var needsSteam: Bool { self == .wineSteam || self == .wineSteamSilent }

        /// Steam starts the game (`-applaunch`), rather than the wrapp.
        public var launchedBySteam: Bool { self == .wineSteam }
    }

    public enum Graphics: String, Codable, Sendable {
        case directDraw = "direct-draw"
        case direct3D = "direct-3d"
    }

    public enum SteamDRM: String, Codable, Sendable {
        case no
        case yesLaunchWhenSteamRunning = "yes-launch-when-steam-running"
        case yesLaunchViaSteamOnly = "yes-launch-via-steam-only"
    }

    /// Where a game lives on Steam, from its app info.
    public struct SteamApp: Hashable, Sendable {
        public let appID: Int
        public let installDir: String
        public let exe: String

        public init(appID: Int, installDir: String, exe: String) {
            self.appID = appID
            self.installDir = installDir
            self.exe = exe
        }
    }

    /// How a Steam-sourced wrapp starts its game, when the game lets the
    /// user choose (`offersSteamLaunchChoice`).
    public enum SteamLaunchMode: String, Codable, CaseIterable, Sendable {
        /// Through Steam: slower, but Steam Cloud keeps the saves.
        case steam
        /// Without Steam, which is removed from the wrapp: quicker and more
        /// reliable, saves stay on this Mac.
        case direct
    }

    public var isOnSteam: Bool { steamAppID != nil }

    public var isOnBigFish: Bool { bigFishProduct != nil }

    /// Only a game known to have no DRM can run without Steam — and the games
    /// ScummVM runs always do (see `steamEngine`), so they offer no choice.
    public var offersSteamLaunchChoice: Bool { isOnSteam && steamDRM == .no && gameEngine != .scummvm }

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
    public func steamEngine(launchMode: SteamLaunchMode?) -> GameEngine {
        if gameEngine == .scummvm { return .scummvm }
        if steamDRM == .no && launchMode == .direct { return gameEngine }
        return .wineSteam
    }

    public init(
        id: String,
        title: String,
        diskCount: Int = 1,
        gameEngine: GameEngine = .wine,
        graphics: Graphics? = nil,
        internalGameExePath: String? = nil,
        steamDRM: SteamDRM? = nil,
        steam: SteamApp? = nil,
        bigFish: Int? = nil,
        installInstructions: String? = nil,
        failedInstallInfo: String? = nil,
        detectionAliases: [String] = [],
        detectionCodes: [String] = [],
        program: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.diskCount = diskCount
        self.gameEngine = gameEngine
        self.graphics = graphics
        self.steamDRM = steamDRM
        self.steamAppID = steam?.appID
        self.steamInstallDir = steam?.installDir
        self.steamExePath = steam?.exe
        self.bigFishProduct = bigFish
        self.internalGameExePath = internalGameExePath
        self.installInstructions = installInstructions
        self.failedInstallInfo = failedInstallInfo
        self.detectionAliases = detectionAliases
        self.detectionCodes = detectionCodes
        self.program = program
        self.displayName = displayName
    }
}
nonisolated extension GameInfo {
    /// What to tell someone clicking through a game's installer themselves,
    /// for a game with no instructions of its own.
    public static let defaultInstallInstructions = """
    Accept the options it suggests, with two exceptions: if it offers to install DirectX, \
    choose not to, and if it asks whether to play the game when it's done, choose No.
    """

    public static let unknownGame = GameInfo(
        id: "unknown",
        title: "Other",
        installInstructions: defaultInstallInstructions
    )
}
