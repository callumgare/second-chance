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
    /// The game's Steam app ID, when it is sold (or was) on Steam.
    public let steamAppID: Int?
    /// The folder Steam installs it into, under `steamapps/common/`.
    public let steamInstallDir: String?
    /// The Windows program Steam starts, relative to `steamInstallDir`, as
    /// its Steam edition's launch says; nil for a game ScummVM runs.
    public let steamExePath: String?
    /// Whether a Steam build asks how the game should start: its Steam
    /// edition has a `launch-mode` input, as a DRM-free game's does.
    public let offersSteamLaunchChoice: Bool
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
    /// Its bundle's id: `nancy-drew/blue-moon`, `freeware/skifree`.
    public let program: String?
    /// The series it belongs to, as people call it: "Nancy Drew".
    public let series: String?
    /// What its app is called, from its bundle: the manifest's
    /// `display-name`, or "<series> - <title>", or the title alone.
    public let displayName: String?

    /// Its program bundle's id: `nancy-drew/blue-moon`. One made by hand,
    /// not from a bundle, has its id.
    public var programID: String { program ?? id }

    /// The name of the game's app, as Finder and the Dock show it.
    public var appName: String { displayName ?? title }
    /// The game's app's file name.
    public var appBundleName: String { appName + ".app" }

    public enum GameEngine: String, Codable, Sendable, CaseIterable {
        case wine
        case scummvm
        case wineSteam = "wine-steam"
        case wineSteamSilent = "wine-steam-silent"
        case dosbox
        /// Basilisk II, a classic 68k Mac emulated (the basilisk module).
        case basilisk

        /// Wine runs the game: every engine but ScummVM, DOSBox and Basilisk II.
        public var runsInWine: Bool { self != .scummvm && self != .dosbox && self != .basilisk }

        /// Steam has to be running, and signed in, before the game starts.
        public var needsSteam: Bool { self == .wineSteam || self == .wineSteamSilent }

        /// Steam starts the game (`-applaunch`), rather than the wrapp.
        public var launchedBySteam: Bool { self == .wineSteam }
    }

    public enum Graphics: String, Codable, Sendable {
        case directDraw = "direct-draw"
        case direct3D = "direct-3d"
    }

    /// Where a game lives on Steam, from its app info.
    public struct SteamApp: Hashable, Sendable {
        public let appID: Int
        public let installDir: String
        public let exe: String?

        public init(appID: Int, installDir: String, exe: String?) {
            self.appID = appID
            self.installDir = installDir
            self.exe = exe
        }
    }

    public var isOnSteam: Bool { steamAppID != nil }

    public var isOnBigFish: Bool { bigFishProduct != nil }

    public init(
        id: String,
        title: String,
        diskCount: Int = 1,
        gameEngine: GameEngine = .wine,
        graphics: Graphics? = nil,
        internalGameExePath: String? = nil,
        steam: SteamApp? = nil,
        offersSteamLaunchChoice: Bool = false,
        bigFish: Int? = nil,
        installInstructions: String? = nil,
        failedInstallInfo: String? = nil,
        detectionAliases: [String] = [],
        detectionCodes: [String] = [],
        program: String? = nil,
        series: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.diskCount = diskCount
        self.gameEngine = gameEngine
        self.graphics = graphics
        self.steamAppID = steam?.appID
        self.steamInstallDir = steam?.installDir
        self.steamExePath = steam?.exe
        self.offersSteamLaunchChoice = offersSteamLaunchChoice
        self.bigFishProduct = bigFish
        self.internalGameExePath = internalGameExePath
        self.installInstructions = installInstructions
        self.failedInstallInfo = failedInstallInfo
        self.detectionAliases = detectionAliases
        self.detectionCodes = detectionCodes
        self.program = program
        self.series = series
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
