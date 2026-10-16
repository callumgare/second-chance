// The public face of the app's game database for the CLI. GameInfo.swift and
// GameInfoProvider.swift in this directory are symlinks into the app's
// sources, so their types are internal; this file copies out what the CLI
// needs into Sendable values.

import Foundation

public struct CatalogGame: Sendable, Hashable {
    /// The slug, e.g. `haunted-carousel`.
    public let slug: String
    public let title: String
    public let diskCount: Int
    /// The `GameEngine` raw value: `wine`, `scummvm`, `wine-steam`, …
    public let engine: String

    /// The wrapp's bundle name, as `WrappBuildHelper.saveWrapp` names it.
    public var wrappName: String { "Nancy Drew - \(title).app" }
}

public enum Catalog {
    /// Every known game, in the app's canonical (chronological) order.
    public static let games: [CatalogGame] = GameInfoProvider.shared.allGames().map {
        CatalogGame(slug: $0.id, title: $0.title, diskCount: $0.diskCount, engine: $0.gameEngine.rawValue)
    }

    public static func game(slug: String) -> CatalogGame? {
        games.first { $0.slug == slug }
    }
}
