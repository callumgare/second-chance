//
//  GameInfoProvider.swift
//  GameCatalog
//
//  Provides game metadata for all Nancy Drew titles, from the program
//  bundles in Bundles/

import Foundation
import Synchronization

/// Provides game information for all supported Nancy Drew titles
public nonisolated final class GameInfoProvider: Sendable {
    public static let shared = GameInfoProvider()

    /// The games known, in order, and by slug. A `Mutex` because
    /// `add(_:)` may change them, once, at start-up.
    private let state: Mutex<(list: [GameInfo], bySlug: [String: GameInfo])>

    /// Every game a bundle in Bundles/ describes, in the order lists show
    /// them: generated from the bundles by `sc generate`
    /// (GameInfoProvider+Bundles.swift). Other games for tests alone.
    init(games: [GameInfo] = GameInfoProvider.bundledGames) {
        state = Mutex((games, Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })))
    }

    /// Adds `games` from bundles beyond the shipped ones
    /// (`SECOND_CHANCE_EXTRA_BUNDLES`, docs/program-bundles.md#extra-bundles):
    /// each after the shipped games, or in place of the shipped game with
    /// its slug. Made at start-up, before anything asks for a game.
    public func add(_ games: [GameInfo]) {
        state.withLock { state in
            for game in games {
                if let index = state.list.firstIndex(where: { $0.id == game.id }) {
                    state.list[index] = game
                } else {
                    state.list.append(game)
                }
                state.bySlug[game.id] = game
            }
        }
    }

    /// Retrieve game information by slug
    public func gameInfo(for slug: String) -> GameInfo {
        state.withLock { $0.bySlug[slug] } ?? GameInfo.unknownGame
    }

    /// Get all known games in their canonical order
    public func allGames() -> [GameInfo] {
        state.withLock { $0.list }
    }

    /// The game a Big Fish SKU is an edition of, in whichever language.
    public func game(forBigFish sku: BigFishSKU) -> GameInfo? {
        allGames().first { $0.bigFishProduct == sku.product }
    }
}
