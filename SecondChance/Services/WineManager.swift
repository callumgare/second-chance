//
//  WineManager.swift
//  SecondChance
//
//  A wrapp's Wine prefix: making it, caching it, and mounting discs into it.
//  Running Wine programs is `Wine`'s (SecondChanceKit's Wine/).

import Foundation
import Logging
import SecondChanceKit
import WrappBuilder

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WineManager")

/// Makes and caches wrapps' Wine prefixes.
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

    // MARK: - Wine Prefix Management

    /// The prefix layer's key for a wrapp: the Wine engine it carries, by
    /// its version and prepared hash, and the wine module's `prefix` stage,
    /// which the build sets a prefix up with.
    nonisolated static func prefixLayerKey(for wrappPath: URL) throws -> LayerKey {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        let installed = EngineInstall.installed(in: wrappPath.appendingPathComponent("Contents"))
        guard let wine = installed.first(where: { $0.module == ModuleID.wine.rawValue }) else {
            throw WrappBuildError.templateDamaged("The wrapp at \(wrappPath.path) has no Wine engine")
        }
        let engine = "\(wine.version) \(wine.hash)"
        return try WineBuild.prefixLayerKey(engineVersion: engine, stage: try prefixStage(),
                                            winetricks: Bundle.main.url(forResource: "winetricks", withExtension: nil))
    }

    /// Clear every cached layer, the prefix among them.
    func clearCache() throws {
        try layers.removeAll()
        try? FileManager.default.removeItem(at: Self.formerPrefixCache)
        logger.notice("✓ Cleared the layer cache")
    }

    /// A prefix that was made but couldn't be set up fully, so isn't kept
    /// for the builds after this one.
    private struct NotKept: Error {}

    /// Give the wrapp a new Wine prefix: the cached one when it was made from
    /// the same engine and set-up, otherwise made now, reporting its steps on
    /// the build's `bus`, and cached. A build that wants it while another
    /// makes it waits, then clones that one.
    func createWinePrefix(at wrappPath: URL, bus: EventBus<AppEvent>) async throws {
        let prefixPath = WrappLayout(app: wrappPath).prefix
        let layers = layers
        let key = try await Blocking.run { () throws -> LayerKey in
            try? FileManager.default.removeItem(at: Self.formerPrefixCache)
            return try Self.prefixLayerKey(for: wrappPath)
        }
        guard LayerCachePolicy.current() != .off else {
            _ = try await makeWinePrefix(at: wrappPath, bus: bus)
            return
        }
        if let why = layers.explain(key) {
            logger.notice("No cached Wine prefix to use (\(why)): making one")
        }
        var made = false
        do {
            let (layer, built) = try await layers.layer(for: key) { content in
                let configured = try await makeWinePrefix(at: wrappPath, bus: bus)
                made = true
                guard configured else { throw NotKept() }
                logger.notice("Caching Wine prefix \(key.hash.prefix(12))...")
                try await Blocking.run {
                    if clonefile(prefixPath.path, content.path, 0) != 0 {
                        logger.notice("Copying the Wine prefix into the cache, as it's on another volume")
                        try FileManager.default.copyItem(at: prefixPath, to: content)
                    }
                }
                return nil
            }
            if built {
                logger.notice("✓ Cached Wine prefix \(key.hash.prefix(12))")
                return
            }
            logger.notice("✓ Using cached Wine prefix \(key.hash.prefix(12))")
            let restored = try await Blocking.run { () throws -> LayerStore.Restored in
                try? FileManager.default.removeItem(at: prefixPath)
                return try layers.restore(layer, to: prefixPath)
            }
            if restored == .copied {
                logger.notice("Copied the cached Wine prefix, as the cache is on another volume from the build")
            }
        } catch {
            // Caching is only a saving for the next build: one that made its
            // prefix carries on with it.
            guard made else { throw error }
            if error is NotKept {
                logger.warning("Not caching this Wine prefix: the next build makes its own")
            } else {
                logger.warning("Couldn't cache the Wine prefix, so the next build will make its own: \(error.localizedDescription)")
            }
        }
        // A prefix cached when prefixes had a Z: showing the whole Mac.
        Wine(wrapp: wrappPath).drives.block("z")
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

    /// A registry key the set-up names.
    static func registryKey(_ name: String) -> WineRegistry.Key {
        switch name {
        case "mac-driver": #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
        case "direct3d": #"HKEY_CURRENT_USER\Software\Wine\Direct3D"#
        default: .x11Driver
        }
    }

    /// Make the prefix from scratch: wineboot's, then the wine module's
    /// `prefix` stage's steps, in order. What it does is the prefix layer's,
    /// so a change here raises `WineBuild.prefixCodeRevision`.
    private func makeWinePrefix(at wrappPath: URL, bus: EventBus<AppEvent>) async throws -> Bool {
        let wine = Wine(wrapp: wrappPath)
        try await wine.run(.wine(["wineboot", "-u"]))
        try await wine.server.waitUntilProgramsExit(timeout: nil)
        try await runPrefixStage(at: wrappPath, bus: bus)
        return true
    }

    /// The wine module's `prefix` stage's steps, run in the prefix of the
    /// wrapp at `wrappPath`: a new one, or an old wrapp's, which the
    /// `wine-prefix` update brings up to this stage with its game left
    /// installed. Wine's server is let finish, so every registry change and
    /// file is written before the prefix is cached.
    func runPrefixStage(at wrappPath: URL, bus: EventBus<AppEvent>) async throws {
        let steps = WineSteps(bus: bus)
        for step in try Self.prefixStage().steps {
            try await steps.run(step, wrappPath: wrappPath)
        }
        try await Wine(wrapp: wrappPath).server.waitUntilProgramsExit(timeout: nil)
    }

    /// Move the prefix of the wrapp at `wrappPath`, made by another Wine of
    /// the same major version, to the wrapp's own: `wineboot -u`, which
    /// rewrites only Wine's own files.
    func movePrefix(at wrappPath: URL) async throws {
        let wine = Wine(wrapp: wrappPath)
        try await wine.run(.wine(["wineboot", "-u"]))
        try await wine.server.waitUntilProgramsExit(timeout: nil)
    }
}
