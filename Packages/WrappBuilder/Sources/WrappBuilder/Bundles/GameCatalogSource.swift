//
//  GameCatalogSource.swift
//  WrappBuilder
//
//  GameCatalog's table of games, worked out from the bundles.

import Foundation
import GameCatalog

/// GameCatalog's table, made from the bundles: `sc bundle catalog` writes
/// it to `GameInfoProvider+Bundles.swift`, and a test fails when the file
/// there isn't what the bundles make. Generated and checked in, rather than
/// made by a build plugin, so GameCatalog stays Foundation-only and the apps,
/// the wrapps, WrappPuppeteer and `sc` needn't read YAML.
public nonisolated enum GameCatalogSource {
    /// Where the generated file lives, from the repo's root.
    public static let path = "Packages/GameCatalog/Sources/GameCatalog/GameInfoProvider+Bundles.swift"

    /// The game each bundle describes, in the order lists show them: by
    /// series, then `series-order`, then id.
    public static func games(from bundles: [ProgramBundle]) -> [GameInfo] {
        bundles.map(\.manifest)
            .sorted { ($0.series ?? "", $0.seriesOrder ?? .max, $0.id) < ($1.series ?? "", $1.seriesOrder ?? .max, $1.id) }
            .map(gameInfo)
    }

    /// The game a manifest describes, as today's code knows games.
    public static func gameInfo(_ manifest: Manifest) -> GameInfo {
        let editions = manifest.editions
        let disc = editions.first { $0.source == .disc }
        let steamEdition = editions.first { $0.source == .steam }
        let steamInput = steamEdition?.inputs?.first
        let steam = steamInput.flatMap { input -> GameInfo.SteamApp? in
            guard let appID = input.appId, let folder = input.commonFolder, let exe = input.exe else { return nil }
            return GameInfo.SteamApp(appID: appID, installDir: folder, exe: exe)
        }
        let exe = manifest.variants?.lazy.compactMap { $0.launch?.wine?.exe }.first
        let graphics = manifest.variants?.lazy.compactMap { $0.launch?.wine?.graphics }.first
        return GameInfo(
            id: manifest.name,
            title: manifest.title,
            diskCount: disc?.inputs?.count ?? 1,
            gameEngine: manifest.variants?.contains { $0.id == "scummvm" } == true ? .scummvm : .wine,
            graphics: graphics.flatMap(GameInfo.Graphics.init(rawValue:)),
            // Today's paths are from the root of drive C.
            internalGameExePath: exe.map { $0.hasPrefix("C:") ? String($0.dropFirst(2)) : $0 },
            steamDRM: steamEdition?.drm.flatMap(steamDRM),
            steam: steam,
            bigFish: editions.first { $0.source == .bigFish }?.inputs?.first?.product,
            doesNotExitInNonInteractiveMode: editions.contains { $0.installer?.stubborn == true },
            detectionAliases: unique(editions.flatMap { $0.detect?.aliases ?? [] }),
            detectionCodes: unique(editions.flatMap { $0.detect?.codes ?? [] })
        )
    }

    /// The manifest's `drm`, as today's code calls it.
    static func steamDRM(_ drm: String) -> GameInfo.SteamDRM? {
        switch drm {
        case "no": .no
        case "launch-when-steam-running": .yesLaunchWhenSteamRunning
        case "launch-via-steam-only": .yesLaunchViaSteamOnly
        default: nil
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - The Swift source

    /// The generated file's text.
    public static func source(for games: [GameInfo]) -> String {
        var lines = [
            "//",
            "//  GameInfoProvider+Bundles.swift",
            "//  GameCatalog",
            "//",
            "//  Generated from the program bundles in Bundles/ by `sc bundle catalog`.",
            "//  Don't edit it: change the bundles and run that again. A test fails",
            "//  when this file isn't what the bundles make.",
            "",
            "nonisolated extension GameInfoProvider {",
            "    /// Every game a bundle describes, in the order lists show them.",
            "    static let bundledGames: [GameInfo] = [",
        ]
        for game in games {
            lines.append("        GameInfo(")
            var arguments = [
                "id: \(literal(game.id))",
                "title: \(literal(game.title))",
                "diskCount: \(game.diskCount)",
            ]
            if game.gameEngine != .wine { arguments.append("gameEngine: .\(engineCase(game.gameEngine))") }
            if let graphics = game.graphics { arguments.append("graphics: .\(graphicsCase(graphics))") }
            if let exe = game.internalGameExePath { arguments.append("internalGameExePath: \(literal(exe))") }
            if let drm = game.steamDRM { arguments.append("steamDRM: .\(drmCase(drm))") }
            if let appID = game.steamAppID, let folder = game.steamInstallDir, let exe = game.steamExePath {
                arguments.append("steam: .init(appID: \(appID), installDir: \(literal(folder)), exe: \(literal(exe)))")
            }
            if let product = game.bigFishProduct { arguments.append("bigFish: \(product)") }
            if game.doesNotExitInNonInteractiveMode { arguments.append("doesNotExitInNonInteractiveMode: true") }
            if !game.detectionAliases.isEmpty { arguments.append("detectionAliases: [\(game.detectionAliases.map(literal).joined(separator: ", "))]") }
            if !game.detectionCodes.isEmpty { arguments.append("detectionCodes: [\(game.detectionCodes.map(literal).joined(separator: ", "))]") }
            lines += arguments.enumerated().map { "            \($1)\($0 == arguments.count - 1 ? "" : ",")" }
            lines.append("        ),")
        }
        lines += ["    ]", "}", ""]
        return lines.joined(separator: "\n")
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func engineCase(_ engine: GameInfo.GameEngine) -> String {
        switch engine {
        case .wine: "wine"
        case .scummvm: "scummvm"
        case .wineSteam: "wineSteam"
        case .wineSteamSilent: "wineSteamSilent"
        }
    }

    private static func graphicsCase(_ graphics: GameInfo.Graphics) -> String {
        switch graphics {
        case .directDraw: "directDraw"
        case .direct3D: "direct3D"
        }
    }

    private static func drmCase(_ drm: GameInfo.SteamDRM) -> String {
        switch drm {
        case .no: "no"
        case .yesLaunchWhenSteamRunning: "yesLaunchWhenSteamRunning"
        case .yesLaunchViaSteamOnly: "yesLaunchViaSteamOnly"
        }
    }
}
