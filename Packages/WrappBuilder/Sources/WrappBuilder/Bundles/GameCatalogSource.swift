//
//  GameCatalogSource.swift
//  WrappBuilder
//
//  GameCatalog's table of games, worked out from the bundles.

import Foundation
import GameCatalog
import WrappFormat
import WrappModules

/// GameCatalog's table, made from the bundles: `sc generate` writes
/// it to `GameInfoProvider+Bundles.swift`, and a test fails when the file
/// there isn't what the bundles make. Generated and checked in, rather than
/// made by a build plugin, so GameCatalog stays Foundation-only and the apps,
/// the wrapps, WrappPuppeteer and `sc` needn't read YAML.
public nonisolated enum GameCatalogSource {
    /// Where the generated file lives, from the repo's root.
    public static let path = "Packages/GameCatalog/Sources/GameCatalog/GameInfoProvider+Bundles.swift"

    /// The game each bundle describes, in the order lists show them: by
    /// series, then `series-order`, then id. Its engine, program and
    /// graphics are its default edition's planned launch's; where its program
    /// is, as its module's kit says (`places`).
    public static func games(from bundles: [ProgramBundle], modules: [ModuleFolder], places: PathPlaces) throws -> [GameInfo] {
        try bundles
            .sorted { ($0.manifest.series ?? "", $0.manifest.seriesOrder ?? .max, $0.manifest.id)
                < ($1.manifest.series ?? "", $1.manifest.seriesOrder ?? .max, $1.manifest.id) }
            .map { bundle in
                gameInfo(bundle.manifest, launch: try defaultLaunch(of: bundle, modules: modules),
                         steamLaunch: try launch(of: bundle, edition: { $0.source == .steam }, modules: modules), places: places)
            }
    }

    /// The launch of the bundle's first edition with a stage, planned for
    /// both kinds of Mac: the catalogue is checked in, so it mustn't depend
    /// on which Mac made it, and a launch that differs between them fails.
    public static func defaultLaunch(of bundle: ProgramBundle, modules: [ModuleFolder]) throws -> RecordedLaunch? {
        try launch(of: bundle, edition: { _ in true }, modules: modules)
    }

    /// The launch of the bundle's first edition with a stage that `matches`,
    /// with its choices' defaults, planned for both kinds of Mac.
    static func launch(of bundle: ProgramBundle, edition matches: (Manifest.Edition) -> Bool,
                       modules: [ModuleFolder]) throws -> RecordedLaunch? {
        guard let edition = bundle.manifest.editions.first(where: { $0.build?.target != nil && matches($0) }) else { return nil }
        let text = try String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8)
        let planner = BuildPlanner(bundle: bundle, wrappfile: try WrappfileParser.parse(text), modules: modules)
        let launches = try ["arm64", "x86_64"].map { arch in
            try planner.plan(edition: edition.id, conditions: BuildConditions(arch: arch, macos: 15))?.launch
        }
        guard launches[0] == launches[1] else {
            throw BuildPlanner.PlanError(description: "\(bundle.manifest.id)'s \(edition.id) launches one way on arm64 and another on x86_64")
        }
        return launches[0]
    }

    /// The game a manifest describes, as today's code knows games, with its
    /// default edition's launch.
    public static func gameInfo(_ manifest: Manifest, launch: RecordedLaunch?, steamLaunch: RecordedLaunch? = nil,
                                places: PathPlaces) -> GameInfo {
        let editions = manifest.editions
        let disc = editions.first { $0.source == .disc }
        let steamEdition = editions.first { $0.source == .steam }
        let steamInput = steamEdition?.inputs?.first
        // The program Steam starts, or the one Wine does when the default
        // choice takes Steam away: in the folder Steam installs the game in.
        let steamExe = (steamLaunch?.options["steam.exe"] ?? (steamLaunch?.launcher() == .wine ? steamLaunch?.program : nil))
            .map { String($0.split(separator: "/").last ?? "") }
        let steam = steamInput.flatMap { input -> GameInfo.SteamApp? in
            guard let appID = input.appId, let folder = input.commonFolder else { return nil }
            return GameInfo.SteamApp(appID: appID, installDir: folder, exe: steamExe)
        }
        let launcher = launch?.launcher()
        // Today's paths are from the root of the drive the program's on, as
        // the program's module says; a program on no drive has none.
        let exe = launch.flatMap { places.legacyProgramPath(of: $0.program) }
        return GameInfo(
            id: manifest.name,
            title: manifest.title,
            diskCount: disc?.inputs?.count ?? 1,
            gameEngine: Self.engine(of: launcher),
            graphics: launch?.graphics,
            internalGameExePath: exe,
            steam: steam,
            offersSteamLaunchChoice: steamInput != nil && steamEdition?.choice("launch-mode") != nil,
            bigFish: editions.first { $0.source == .bigFish }?.inputs?.first?.product,
            detectionAliases: unique(editions.flatMap { $0.detect?.aliases ?? [] }),
            detectionCodes: unique(editions.flatMap { $0.detect?.codes ?? [] }),
            program: manifest.id,
            series: manifest.series,
            displayName: appName(of: manifest)
        )
    }

    /// What the program's app is called: the manifest's `display-name`, with
    /// `{title}` and `{series}` filled in, or "<series> - <title>" with a
    /// series, or the title alone.
    static func appName(of manifest: Manifest) -> String {
        let name = manifest.displayName ?? (manifest.series == nil ? "{title}" : "{series} - {title}")
        return name.replacingOccurrences(of: "{title}", with: manifest.title)
            .replacingOccurrences(of: "{series}", with: manifest.series ?? "")
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
            "//  Generated from the program bundles in Bundles/ by `sc generate`.",
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
            if let appID = game.steamAppID, let folder = game.steamInstallDir {
                let exe = game.steamExePath.map(literal) ?? "nil"
                arguments.append("steam: .init(appID: \(appID), installDir: \(literal(folder)), exe: \(exe))")
            }
            if game.offersSteamLaunchChoice { arguments.append("offersSteamLaunchChoice: true") }
            if let product = game.bigFishProduct { arguments.append("bigFish: \(product)") }
            if !game.detectionAliases.isEmpty { arguments.append("detectionAliases: [\(game.detectionAliases.map(literal).joined(separator: ", "))]") }
            if !game.detectionCodes.isEmpty { arguments.append("detectionCodes: [\(game.detectionCodes.map(literal).joined(separator: ", "))]") }
            if let program = game.program { arguments.append("program: \(literal(program))") }
            if let series = game.series { arguments.append("series: \(literal(series))") }
            if let name = game.displayName { arguments.append("displayName: \(literal(name))") }
            lines += arguments.enumerated().map { "            \($1)\($0 == arguments.count - 1 ? "" : ",")" }
            lines.append("        ),")
        }
        lines += ["    ]", "}", ""]
        return lines.joined(separator: "\n")
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Today's engine for a program its launcher starts: Wine for every
    /// launcher but ScummVM, DOSBox and Basilisk II.
    static func engine(of launcher: ModuleID?) -> GameInfo.GameEngine {
        switch launcher {
        case .scummvm?: .scummvm
        case .dosbox?: .dosbox
        case .basilisk?: .basilisk
        default: .wine
        }
    }

    private static func engineCase(_ engine: GameInfo.GameEngine) -> String {
        switch engine {
        case .wine: "wine"
        case .scummvm: "scummvm"
        case .wineSteam: "wineSteam"
        case .wineSteamSilent: "wineSteamSilent"
        case .dosbox: "dosbox"
        case .basilisk: "basilisk"
        }
    }

    private static func graphicsCase(_ graphics: GameInfo.Graphics) -> String {
        switch graphics {
        case .directDraw: "directDraw"
        case .direct3D: "direct3D"
        }
    }
}
