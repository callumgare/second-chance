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

    private let fileManager = FileManager.default
    private let prefixCacheDir: URL
    /// Held while a build looks in the cache and, finding nothing, makes the
    /// prefix and caches it: builds running side by side would otherwise
    /// each make one, and remove the cache from under each other.
    private let prefixCreation = AsyncMutex()

    private init() {
        // Set up prefix cache directory in user's Caches (persists between runs)
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/wine-prefix-cache")
        prefixCacheDir = cacheDir
        try? fileManager.createDirectory(at: prefixCacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Wine Prefix Management

    /// The prefix cache key for a wrapp: the build, plus the Wine engine it
    /// carries. A prefix is only reused by the engine that created it, so a
    /// Wine upgrade starts a fresh one without anyone clearing the cache.
    private func getBuildIdentifier(for wrappPath: URL) -> String {
        #if DEBUG
        // In debug mode the build part is static, so the cache persists across builds
        let build = "dev"
        #else
        // In release mode, use the bundle version to invalidate cache on updates
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        #endif
        let versionFile = WrappLayout(app: wrappPath).wine.appendingPathComponent("version")
        let engine: String?
        do {
            engine = try String(contentsOf: versionFile, encoding: .utf8)
        } catch {
            logger.warning("Couldn't read the Wine engine's version from \(versionFile.path), so the prefix cache isn't keyed on it: \(error.localizedDescription)")
            engine = nil
        }
        return Self.prefixCacheKey(build: build, engineVersion: engine)
    }

    /// `build`, then the engine's version as a path-safe slug:
    /// "wine sikarugir 10.0 (revision 8)" → "dev-wine-sikarugir-10-0-revision-8".
    nonisolated static func prefixCacheKey(build: String, engineVersion: String?) -> String {
        let slug = (engineVersion ?? "")
            .lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
        return slug.isEmpty ? build : "\(build)-\(slug)"
    }

    /// Get the cached Wine prefix if available and valid
    private func getCachedPrefix(buildId: String) -> URL? {
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)
        let cachedPrefix = cachedPrefixDir.appendingPathComponent("prefix")

        // Check if cached prefix exists and is a directory. A prefix is
        // only ever renamed into place whole (`cachePrefix`).
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cachedPrefix.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        // Verify it has the expected structure
        let driveCPath = cachedPrefix.appendingPathComponent("drive_c")
        var isDriveCDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: driveCPath.path, isDirectory: &isDriveCDirectory),
              isDriveCDirectory.boolValue else {
            return nil
        }

        return cachedPrefix
    }

    /// Save Wine prefix to cache: hundreds of MB, copied off the main thread.
    private func cachePrefix(from sourcePath: URL, buildId: String) async throws {
        let prefixCacheDir = self.prefixCacheDir
        try await Blocking.run { try Self.cachePrefix(from: sourcePath, buildId: buildId, in: prefixCacheDir) }
    }

    private nonisolated static func cachePrefix(from sourcePath: URL, buildId: String, in prefixCacheDir: URL) throws {
        let fileManager = FileManager.default
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)

        logger.notice("Caching Wine prefix for build: \(buildId)...")

        // Copied in under a hidden name first, then renamed into place, so a
        // build looking in the cache meanwhile never takes half a prefix.
        let incoming = prefixCacheDir.appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourcePath, to: incoming.appendingPathComponent("prefix"))
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw error
        }

        // Remove old cache for this build if it exists, and every other build's:
        // a prefix only serves the build and engine that made it, and each is
        // hundreds of MB.
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: prefixCacheDir, includingPropertiesForKeys: nil)
        } catch {
            logger.warning("Couldn't list the Wine prefix cache to remove old prefixes: \(error.localizedDescription)")
            entries = []
        }
        // By name: the listing's URLs end in a slash where `incoming` doesn't,
        // so they never compare equal. Another process (a second app, or a
        // test run beside this one) may be copying in its own prefix, and
        // removing that would fail its rename, so only an old one is left
        // over from a copy that never finished.
        for entry in entries where entry.lastPathComponent != incoming.lastPathComponent
            && !Self.isAnotherCopyInProgress(entry) {
            do {
                try fileManager.removeItem(at: entry)
                if entry.lastPathComponent != buildId && !entry.lastPathComponent.hasPrefix(".") {
                    logger.notice("Removed the cached Wine prefix for build \(entry.lastPathComponent)")
                }
            } catch {
                logger.warning("Couldn't remove cached Wine prefix \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        try fileManager.moveItem(at: incoming, to: cachedPrefixDir)
        logger.notice("✓ Cached Wine prefix for build: \(buildId)")
    }

    /// Whether `entry` is a prefix another process is still copying into the
    /// cache: an `.incoming-` folder changed within the last hour.
    nonisolated static func isAnotherCopyInProgress(_ entry: URL, now: Date = Date()) -> Bool {
        guard entry.lastPathComponent.hasPrefix(".incoming-") else { return false }
        let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < 3600
    }

    /// Clear all cached Wine prefixes
    func clearCache() throws {
        if fileManager.fileExists(atPath: prefixCacheDir.path) {
            try fileManager.removeItem(at: prefixCacheDir)
            logger.notice("✓ Cleared Wine prefix cache")
        } else {
            logger.notice("✓ Wine prefix cache is already empty")
        }
    }

    /// Create a new Wine prefix at the specified path, reporting its steps on
    /// the build's `bus`.
    func createWinePrefix(at wrappPath: URL, bus: EventBus<AppEvent>) async throws {
        let prefixPath = WrappLayout(app: wrappPath).prefix
        let buildId = getBuildIdentifier(for: wrappPath)

        // A build that finds the cache empty makes the prefix while any
        // other waits, then finds it cached.
        let cachedPrefix = try await prefixCreation.withLock { () -> URL? in
            if let cachedPrefix = getCachedPrefix(buildId: buildId) { return cachedPrefix }
            try await makeWinePrefix(at: wrappPath, prefixPath: prefixPath, buildId: buildId, bus: bus)
            return nil
        }
        guard let cachedPrefix else { return }
        logger.notice("✓ Using cached Wine prefix (build: \(buildId))")

        // Copy cached prefix to wrapp: hundreds of MB, so off the main thread.
        try await Blocking.run {
            try? FileManager.default.removeItem(at: prefixPath)
            try FileManager.default.copyItem(at: cachedPrefix, to: prefixPath)
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

    /// Make the prefix from scratch, and cache it.
    private func makeWinePrefix(at wrappPath: URL, prefixPath: URL, buildId: String, bus: EventBus<AppEvent>) async throws {

        let wine = Wine(wrapp: wrappPath)
        let winetricks = Winetricks(wine: wine)

        // Run wineboot to initialize (wineboot is a Windows program, so run it through wine)
        try await wine.run(.wine(["wineboot", "-u"]))

        // Wait for wineserver to finish
        try await wine.server.waitUntilProgramsExit(timeout: nil)

        // The rest is the wine module's data (Modules/wine/prefix.yaml), in
        // order. A prefix where cnc-ddraw's settings couldn't be made is
        // never cached for the builds after this one (`configured`).
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

        // Cache the prefix for future use. Only a saving for the next build:
        // this one has its prefix, so it carries on if caching fails.
        guard configured else {
            logger.warning("Not caching this Wine prefix, as cnc-ddraw isn't set up in it: the next build makes its own")
            return
        }
        do {
            try await cachePrefix(from: prefixPath, buildId: buildId)
        } catch {
            logger.warning("Couldn't cache the Wine prefix, so the next build will make its own: \(error.localizedDescription)")
        }
    }
}
