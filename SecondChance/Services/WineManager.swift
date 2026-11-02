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

    /// The prefix layer's key for a wrapp: the Wine engine it carries, and
    /// what the build sets a prefix up with.
    nonisolated static func prefixLayerKey(for wrappPath: URL) throws -> LayerKey {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        let versionFile = WrappLayout(app: wrappPath).wine.appendingPathComponent("version")
        let engine: String
        do {
            engine = try String(contentsOf: versionFile, encoding: .utf8)
        } catch {
            throw WrappBuildError.templateDamaged("Couldn't read the Wine engine's version from \(versionFile.path): \(error.localizedDescription)")
        }
        return try WineBuild.prefixLayerKey(engineVersion: engine, modules: resources.appendingPathComponent("Modules"),
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
                // A prefix where cnc-ddraw's settings couldn't be made is
                // never cached for the builds after this one.
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
                logger.warning("Not caching this Wine prefix, as cnc-ddraw isn't set up in it: the next build makes its own")
            } else {
                logger.warning("Couldn't cache the Wine prefix, so the next build will make its own: \(error.localizedDescription)")
            }
        }
        // A prefix cached when prefixes had a Z: showing the whole Mac.
        Wine(wrapp: wrappPath).drives.block("z")
    }

    /// The wine module's prefix set-up, from the modules in Second Chance's
    /// resources.
    nonisolated static func prefixSetup() throws -> WineBuild.PrefixSetup {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        return try WineBuild.prefixSetup(modules: resources.appendingPathComponent("Modules"))
    }

    /// What the build's progress says during a step of the set-up.
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

    /// Set `settings` in cnc-ddraw's ddraw.ini, each `key=value` line
    /// replaced. Whether every one is now set. See
    /// docs/wine-in-process-helpers.md before changing them.
    nonisolated static func configureDdrawIni(_ file: URL, settings: [String: String]) -> Bool {
        do {
            var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var found = Set<String>()
            for index in lines.indices {
                let line = lines[index]
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<equals])
                guard let value = settings[key] else { continue }
                lines[index] = "\(key)=\(value)"
                found.insert(key)
            }
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            let missing = Set(settings.keys).subtracting(found)
            guard missing.isEmpty else {
                logger.error("cnc-ddraw's ddraw.ini doesn't have the \(missing.sorted().joined(separator: ", ")) settings to change: is this another cnc-ddraw?")
                return false
            }
            logger.notice("✓ Configured cnc-ddraw: \(settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
            return true
        } catch {
            logger.error("Couldn't configure cnc-ddraw (\(file.path)): \(error.localizedDescription)")
            return false
        }
    }

    /// Make the prefix from scratch: whether every step of the set-up took.
    /// What it does is the prefix layer's, so a change here raises
    /// `WineBuild.prefixCodeRevision`.
    private func makeWinePrefix(at wrappPath: URL, bus: EventBus<AppEvent>) async throws -> Bool {

        let wine = Wine(wrapp: wrappPath)
        let winetricks = Winetricks(wine: wine)

        // Run wineboot to initialize (wineboot is a Windows program, so run it through wine)
        try await wine.run(.wine(["wineboot", "-u"]))

        // Wait for wineserver to finish
        try await wine.server.waitUntilProgramsExit(timeout: nil)

        // The rest is the wine module's data (Modules/wine/prefix.yaml), in
        // order.
        var configured = true
        for step in try Self.prefixSetup().setup {
            if let progress = step.progress.flatMap(Self.progressText) {
                await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: progress)))
            }
            if let value = step.registry {
                try await wine.registry.set(.string(value.value), for: value.name, in: Self.registryKey(value.key))
            }
            if let verb = step.winetricks {
                try await winetricks.install(verb)
            }
            if let settings = step.ddrawIni {
                configured = Self.configureDdrawIni(wine.driveC.appendingPathComponent("windows/syswow64/ddraw.ini"),
                                                    settings: settings) && configured
            }
        }

        // Only the drives a game needs (WineDrives has what each is for),
        // and no Z: showing the whole Mac. The A: drive's place in /tmp
        // stands in for the saves until the wrapp points it at them, and C:
        // is relative so the prefix still works copied into a wrapp.
        wine.drives.removeAll()
        try wine.drives.mount("/tmp/second-chance-nancy-drew-\(UUID().uuidString)", as: "a")
        try wine.drives.mount("../drive_c", as: "c")
        wine.drives.block("bdefghijklmnopqrstuvwxyz")

        // Ensure Wine server is fully shut down before caching
        // This ensures all registry changes and file writes are flushed to disk
        try await wine.server.waitUntilProgramsExit(timeout: nil)
        return configured
    }
}
