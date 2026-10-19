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

    /// The client, and the Steam Service it updates alongside itself. A
    /// cached client over the installer's older service makes Steam ask to
    /// reinstall the service ("Steam Service Error … requires some
    /// maintenance"), so the two are cached and restored together.
    static let folders = [
        (cached: "Steam", inPrefix: SteamClient.steamDirInPrefix),
        (cached: "Common Files Steam", inPrefix: "drive_c/Program Files (x86)/Common Files/Steam"),
    ]

    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SecondChance/steam-client")) {
        self.directory = directory
    }

    /// Lay the cached client and service over the freshly installed ones in
    /// `prefix`. False when there's nothing (complete) cached.
    @discardableResult
    func restore(into prefix: URL) -> Bool {
        let complete = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Steam/steam.exe").path)
            && Self.folders.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.cached).path) }
        guard complete else { return false }
        do {
            for folder in Self.folders {
                let target = prefix.appendingPathComponent(folder.inPrefix)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: directory.appendingPathComponent(folder.cached), to: target)
            }
            logger.notice("Restored the cached Steam client")
            return true
        } catch {
            logger.warning("Couldn't restore the cached Steam client, so Steam will update itself: \(error.localizedDescription)")
            return false
        }
    }

    /// Save the client in `prefix` (after it has run, so it is up to date).
    func save(from prefix: URL) {
        let staging = directory.appendingPathComponent("staging")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for folder in Self.folders {
                try FileManager.default.copyItem(at: prefix.appendingPathComponent(folder.inPrefix),
                                                 to: staging.appendingPathComponent(folder.cached))
            }
            for path in Self.excluded {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent("Steam").appendingPathComponent(path))
            }
            // Swap the whole set in at once, so a restore never pairs a new
            // client with an old service.
            for folder in Self.folders {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(folder.cached))
                try FileManager.default.moveItem(at: staging.appendingPathComponent(folder.cached),
                                                 to: directory.appendingPathComponent(folder.cached))
            }
            try? FileManager.default.removeItem(at: staging)
            logger.notice("Cached the updated Steam client")
        } catch {
            logger.warning("Couldn't cache the Steam client (the next build will update it again): \(error.localizedDescription)")
            for folder in Self.folders { try? FileManager.default.removeItem(at: directory.appendingPathComponent(folder.cached)) }
            try? FileManager.default.removeItem(at: staging)
        }
    }
}
