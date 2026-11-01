//
//  WrappSettings.swift
//  SecondChanceKit
//
//  What a wrapp's AppSettings.plist says about its game.

import Foundation
import GameCatalog

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
    public var steamLaunchMode: GameInfo.SteamLaunchMode?

    enum CodingKeys: String, CodingKey {
        case gameExePath = "GameExePath"
        case engine = "GameEngine"
        case gameSlug = "GameSlug"
        case source = "GameSource"
        case installerDir = "GameInstallerDir"
        case steamAppID = "SteamGameId"
        case steamLaunchMode = "SteamLaunchMode"
    }

    public init(
        gameExePath: String, engine: GameInfo.GameEngine, gameSlug: String?, source: WrappSource?,
        installerDir: String, steamAppID: String? = nil, steamLaunchMode: GameInfo.SteamLaunchMode? = nil
    ) {
        self.gameExePath = gameExePath
        self.engine = engine
        self.gameSlug = gameSlug
        self.source = source
        self.installerDir = installerDir
        self.steamAppID = steamAppID
        self.steamLaunchMode = steamLaunchMode
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
