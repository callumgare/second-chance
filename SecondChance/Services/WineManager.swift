//
//  WineManager.swift
//  SecondChance
//
//  The layer cache a prefix is kept in, the wine module's prefix stage, and
//  the progress text its steps show. Making a prefix is the runner's
//  (`USE wine`, the wine module's executor); running Wine programs is
//  `Wine`'s (SecondChanceKit's Wine/).

import Foundation
import WineExecutor
import Logging
import SecondChanceKit
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WineManager")

/// The layer store builds keep prefixes in, and the prefix stage.
class WineManager {
    static let shared = WineManager()

    /// Where a new prefix is kept: the `USE wine` layer
    /// (docs/wrapp-build.md#the-layer-cache).
    let layers: LayerStore

    init(layers: LayerStore = .standard()) {
        self.layers = layers
    }

    /// Where prefixes were cached before the layer store, removed when
    /// found.
    nonisolated static var formerPrefixCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/wine-prefix-cache")
    }

    /// Clear every cached layer, the prefix among them.
    func clearCache() throws {
        try layers.removeAll()
        try? FileManager.default.removeItem(at: Self.formerPrefixCache)
        logger.notice("✓ Cleared the layer cache")
    }

    /// The wine module's `prefix` stage (`Modules/wine/stages/prefix`), from
    /// the modules in Second Chance's resources: what every prefix is made with.
    nonisolated static func prefixStage() throws -> PlannedStage {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        return try WineBuild.prefixStage(modules: resources.appendingPathComponent("Modules"))
    }

    /// What the build's progress says during a step (`--progress=<id>`).
    nonisolated static func progressText(_ key: String) -> String? {
        switch key {
        case "display": String(localized: "Setting up the game's display")
        case "graphics": String(localized: "Setting up the game's graphics")
        case "disc": String(localized: "Setting up where the game finds its disc")
        default: nil
        }
    }
}
