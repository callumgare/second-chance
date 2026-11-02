//
//  GameInfoProvider.swift
//  GameCatalog
//
//  Provides game metadata for all Nancy Drew titles, from the program
//  bundles in Bundles/

import Foundation

/// Provides game information for all supported Nancy Drew titles
public nonisolated final class GameInfoProvider: Sendable {
    public static let shared = GameInfoProvider()

    private init() {
        games = Dictionary(uniqueKeysWithValues: gamesList.map { ($0.id, $0) })
    }

    /// Every game a bundle in Bundles/ describes, in the order lists show
    /// them: generated from the bundles by `sc bundle catalog`
    /// (GameInfoProvider+Bundles.swift).
    private let gamesList: [GameInfo] = bundledGames

    /// Dictionary for fast lookup by slug
    private let games: [String: GameInfo]

    /// Retrieve game information by slug
    public func gameInfo(for slug: String) -> GameInfo {
        return games[slug] ?? GameInfo.unknownGame
    }

    /// Get all known games in their canonical order
    public func allGames() -> [GameInfo] {
        return gamesList
    }

    /// The game a Big Fish SKU is an edition of, in whichever language.
    public func game(forBigFish sku: BigFishSKU) -> GameInfo? {
        gamesList.first { $0.bigFishProduct == sku.product }
    }
}
