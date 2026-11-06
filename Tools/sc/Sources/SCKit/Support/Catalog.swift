// What the CLI needs of the app's game database (Packages/GameCatalog),
// copied out into plain values.

import Foundation
import GameCatalog
import WrappBuilder

public struct CatalogGame: Sendable, Hashable {
    /// The slug, e.g. `haunted-carousel`.
    public let slug: String
    public let title: String
    public let diskCount: Int
    /// The `GameEngine` raw value: `wine`, `scummvm`, `wine-steam`, …
    public let engine: String
    /// Sold (or once sold) on Steam, so `--from steam` can build it.
    public let isOnSteam: Bool
    /// DRM-free on Steam: the build asks whether to launch it via Steam or directly.
    public let offersSteamLaunchChoice: Bool
    /// Sold by Big Fish Games, so `--from big-fish` can build it (or its free trial).
    public let isOnBigFish: Bool
    /// The wrapp's bundle name, as the app names it (`GameInfo.appBundleName`).
    public let wrappName: String
    /// Its program bundle's id, `nancy-drew/<slug>` or another's.
    public let programID: String
}

public enum Catalog {
    /// Every known game, in the app's canonical (chronological) order, with
    /// those `--bundle` added (`ExtraBundleOptions`).
    public static var games: [CatalogGame] { GameInfoProvider.shared.allGames().map {
        CatalogGame(slug: $0.id, title: $0.title, diskCount: $0.diskCount, engine: $0.gameEngine.rawValue,
                    isOnSteam: $0.isOnSteam, offersSteamLaunchChoice: $0.offersSteamLaunchChoice, isOnBigFish: $0.isOnBigFish,
                    wrappName: $0.appBundleName, programID: $0.programID)
    } }

    public static func game(slug: String) -> CatalogGame? {
        games.first { $0.slug == slug }
    }
}

extension CatalogGame {
    /// Whether its bundle has an edition from `source` (`disc`, `download`).
    func hasEdition(source: String, repo: Repo) -> Bool {
        let manifest = ExtraBundles.folder(of: programID, shippedRoot: repo.bundles).appendingPathComponent("manifest.yaml")
        return (try? String(contentsOf: manifest, encoding: .utf8))?.contains("source: \"\(source)\"") == true
    }
}
