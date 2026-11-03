//
//  WrappSettings.swift
//  WrappFormat
//
//  What a wrapp's AppSettings.plist says about its game.

import Foundation
import GameCatalog
import WrappModules

/// What the build records about a wrapp's game, in its AppSettings.plist
/// (`WrappLayout.settingsFile`): written by `WrappBuildHelper`, read by the
/// wrapp and by WrappPuppeteer. The keys are the ones wrapps have always
/// had, so a wrapp built before this type still reads.
nonisolated public struct WrappSettings: Codable, Sendable, Equatable {
    /// The game's `.exe`, a path from the root of the C: drive with forward
    /// slashes (`/Program Files (x86)/Nancy Drew/Game.exe`). For a game
    /// ScummVM runs, its data folder.
    public var gameExePath: String
    public var engine: GameInfo.GameEngine
    /// The game's `GameInfoProvider` id; nil in a wrapp built before it was
    /// recorded.
    public var gameSlug: String?
    /// Where the game came from; nil in a wrapp built before it was recorded.
    public var source: WrappSource?
    /// Where the installer was put, from the root of the C: drive.
    public var installerDir: String
    /// The game's Steam app ID, for a game installed through Steam.
    public var steamAppID: String?
    /// How a DRM-free Steam game starts, as the person chose when building
    /// it; nil for a game that offered no choice.
    public var steamLaunchMode: String?
    /// For a game installed through Big Fish's Game Manager: the message file
    /// its own Play shortcut opens (`LaunchGame.bfg`), a path from the root of
    /// the C: drive as `gameExePath` is. The wrapp hands it to Big Fish's
    /// `bfgprocess.exe`, whose DRM service starts the game (docs/big-fish.md).
    public var bigFishLaunchFile: String?
    /// The Big Fish SKU of the edition installed (`F2435T1L1`).
    public var bigFishSKU: String?
    /// The game is Big Fish's free trial, which only the integration tests
    /// build: launching it opens the Game Manager, whose Play Now the wrapp
    /// presses itself (docs/big-fish.md).
    public var bigFishTrial: Bool?
    /// How the wrapp starts its program, as its Wrappfile said; nil in a
    /// wrapp built before launches were recorded (`launch` makes one).
    public var recordedLaunch: RecordedLaunch?

    enum CodingKeys: String, CodingKey {
        case gameExePath = "GameExePath"
        case engine = "GameEngine"
        case gameSlug = "GameSlug"
        case source = "GameSource"
        case installerDir = "GameInstallerDir"
        case steamAppID = "SteamGameId"
        case steamLaunchMode = "SteamLaunchMode"
        case bigFishLaunchFile = "BigFishLaunchFile"
        case bigFishSKU = "BigFishSKU"
        case bigFishTrial = "BigFishTrial"
        case recordedLaunch = "Launch"
    }

    public init(
        gameExePath: String, engine: GameInfo.GameEngine, gameSlug: String?, source: WrappSource?,
        installerDir: String, steamAppID: String? = nil, steamLaunchMode: String? = nil,
        bigFishLaunchFile: String? = nil, bigFishSKU: String? = nil, bigFishTrial: Bool? = nil,
        recordedLaunch: RecordedLaunch? = nil
    ) {
        self.gameExePath = gameExePath
        self.engine = engine
        self.gameSlug = gameSlug
        self.source = source
        self.installerDir = installerDir
        self.steamAppID = steamAppID
        self.steamLaunchMode = steamLaunchMode
        self.bigFishLaunchFile = bigFishLaunchFile
        self.bigFishSKU = bigFishSKU
        self.bigFishTrial = bigFishTrial
        self.recordedLaunch = recordedLaunch
    }

    /// The modules the wrapp runs, from its engine: a Wine game with a
    /// `.bfg` to start it is started by Big Fish's DRM.
    public var composition: Composition {
        engine == .wine && bigFishLaunchFile != nil ? Composition(launcher: .bigFish) : Composition(legacy: engine)
    }

    /// How the wrapp starts its program: as recorded, or for a wrapp built
    /// before launches were, the launch its legacy settings mean. A ScummVM
    /// game's data was on the C: drive then, and it was started by ScummVM's
    /// detection rather than its id.
    public var launch: RecordedLaunch {
        if let recordedLaunch { return recordedLaunch }
        switch engine {
        case .scummvm:
            let folder = "/SharedSupport/prefix/drive_c/" + installerDir.drop { $0 == "/" }
            return RecordedLaunch(program: "scummvm:" + (folder.hasSuffix("/") ? folder : folder + "/"))
        case .dosbox:
            return RecordedLaunch(program: "dosbox:C:" + gameExePath)
        case .wineSteam where steamLaunchMode != "direct":
            let exe = "wine:C:" + gameExePath
            return RecordedLaunch(program: "steam://rungameid/\(steamAppID ?? "")", options: ["steam.exe": exe],
                                  fallback: steamLaunchMode == "steam" ? exe : nil)
        default:
            if let bigFishLaunchFile { return RecordedLaunch(program: "big-fish:C:" + bigFishLaunchFile) }
            return RecordedLaunch(program: "wine:C:" + gameExePath)
        }
    }

    /// The settings of the wrapp at `layout`.
    public init(of layout: WrappLayout) throws {
        self = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: layout.settingsFile))
    }

    /// Write these as the settings of the wrapp at `layout`.
    public func write(to layout: WrappLayout) throws {
        try FileManager.default.createDirectory(at: layout.resources, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: layout.settingsFile)
    }
}
