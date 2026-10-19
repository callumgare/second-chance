//
//  SteamClientCache.swift
//  SecondChance
//
//  A copy of the Steam client as it is after updating itself, so each Steam
//  build doesn't download the update again. The Steam installer only lays
//  down a bootstrapper; its first start fetches the client proper.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.SteamClientCache")

nonisolated final class SteamClientCache: @unchecked Sendable {
    static let shared = SteamClientCache()

    /// What the cache leaves out, relative to the Steam folder: the
    /// account's sign-in and licences, its settings, installed games, logs.
    static let excluded = [
        "steamapps", "userdata", "logs", "dumps",
        "config/loginusers.vdf", "config/config.vdf",
        "appcache/packageinfo.vdf",
    ]

    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SecondChance/steam-client")) {
        self.directory = directory
    }

    private var cachedSteam: URL { directory.appendingPathComponent("Steam") }

    /// Lay the cached client over the freshly installed one in `prefix`.
    /// False when there's nothing cached.
    @discardableResult
    func restore(into prefix: URL) -> Bool {
        let steam = prefix.appendingPathComponent(SteamClient.steamDirInPrefix)
        guard FileManager.default.fileExists(atPath: cachedSteam.appendingPathComponent("steam.exe").path) else {
            return false
        }
        do {
            try? FileManager.default.removeItem(at: steam)
            try FileManager.default.copyItem(at: cachedSteam, to: steam)
            logger.notice("Restored the cached Steam client")
            return true
        } catch {
            logger.warning("Couldn't restore the cached Steam client, so Steam will update itself: \(error.localizedDescription)")
            return false
        }
    }

    /// Save the client in `prefix` (after it has run, so it is up to date).
    func save(from prefix: URL) {
        let steam = prefix.appendingPathComponent(SteamClient.steamDirInPrefix)
        let staging = directory.appendingPathComponent("Steam.new")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: steam, to: staging)
            for path in Self.excluded {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(path))
            }
            if FileManager.default.fileExists(atPath: cachedSteam.path) {
                _ = try FileManager.default.replaceItemAt(cachedSteam, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: cachedSteam)
            }
            logger.notice("Cached the updated Steam client")
        } catch {
            logger.warning("Couldn't cache the Steam client (the next build will update it again): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: staging)
        }
    }
}
