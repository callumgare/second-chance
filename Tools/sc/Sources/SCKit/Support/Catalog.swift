// What the CLI needs of the app's game database (Packages/GameCatalog),
// copied out into plain values.

import Foundation
import GameCatalog

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
}

public enum Catalog {
    /// Every known game, in the app's canonical (chronological) order.
    public static let games: [CatalogGame] = GameInfoProvider.shared.allGames().map {
        CatalogGame(slug: $0.id, title: $0.title, diskCount: $0.diskCount, engine: $0.gameEngine.rawValue,
                    isOnSteam: $0.isOnSteam, offersSteamLaunchChoice: $0.offersSteamLaunchChoice, isOnBigFish: $0.isOnBigFish,
                    wrappName: $0.appBundleName)
    }

    public static func game(slug: String) -> CatalogGame? {
        games.first { $0.slug == slug }
    }
}
