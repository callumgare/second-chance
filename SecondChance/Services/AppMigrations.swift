//
//  AppMigrations.swift
//  SecondChance
//
//  What Second Chance moves when it starts, from where an earlier release
//  kept it: Steam's sign-in, its lock and client, and Big Fish's sign-in,
//  into the steam and big-fish modules' stores (decision 23 of the builders
//  plan; docs/steam.md#where-the-sign-in-lives).

import Foundation
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.AppMigrations")

nonisolated enum AppMigrations {
    /// Where things were, and where they go: each under `appSupport` and
    /// `caches`, a test's or the real ones.
    struct Roots {
        var appSupport: URL
        var caches: URL

        static var real: Roots { Roots(appSupport: StoreLocations.realAppSupport, caches: StoreLocations.realCaches) }

        var stores: URL { appSupport.appendingPathComponent("SecondChance/stores", isDirectory: true) }
        var steamSignIn: URL { stores.appendingPathComponent("steam/sign-in", isDirectory: true) }
        var steamLock: URL { stores.appendingPathComponent("locks/steam.steam.lock") }
        var bigFishSignIn: URL { stores.appendingPathComponent("big-fish/sign-in", isDirectory: true) }
        var steamClient: URL { caches.appendingPathComponent("SecondChance/stores/global/steam/client", isDirectory: true) }
    }

    /// Everything, once: what's moved already is left alone.
    static func run(_ roots: Roots = .real) {
        migrateSteam(roots)
        // A cache, and nothing released reads it from elsewhere.
        move(roots.caches.appendingPathComponent("SecondChance/steam-client"), to: roots.steamClient, linkBack: false)
        // The prefix cache from before the layer store.
        let formerPrefixCache = roots.caches.appendingPathComponent("SecondChance/wine-prefix-cache")
        if FileManager.default.fileExists(atPath: formerPrefixCache.path) {
            do {
                try FileManager.default.removeItem(at: formerPrefixCache)
                logger.notice("Removed the prefix cache from before the layer store")
            } catch {
                logger.error("Couldn't remove \(formerPrefixCache.path): \(error.localizedDescription)")
            }
        }
        // Big Fish's sign-in isn't released: moved, no link.
        move(roots.appSupport.appendingPathComponent("SecondChance/BigFish/sign-in.reg"),
             to: roots.bigFishSignIn.appendingPathComponent("sign-in.reg"), linkBack: false)
    }

    /// Steam shipped in 1.1.0, whose apps keep using `SecondChance/Steam`:
    /// what's in it moves into the sign-in store, and the folder becomes a
    /// link to the store. So a 1.1.0 app reads and saves the same session in
    /// one real folder (its save swaps `session.new` in with
    /// `replaceItemAt`, which fails on a link to a folder), and locks the
    /// same `session.lock`. Its `active-wrapp.lock` is a link in the store
    /// to the Steam lock every app takes, made if there's none yet, so an
    /// `flock` through it excludes the new apps and builds.
    static func migrateSteam(_ roots: Roots) {
        let files = FileManager.default
        let old = roots.appSupport.appendingPathComponent("SecondChance/Steam", isDirectory: true)
        let store = roots.steamSignIn
        do {
            try files.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? files.destinationOfSymbolicLink(atPath: old.path)) == nil, files.fileExists(atPath: old.path) {
                for name in try files.contentsOfDirectory(atPath: old.path) {
                    let item = old.appendingPathComponent(name)
                    // Links an earlier build of this release left, item by item.
                    if (try? files.destinationOfSymbolicLink(atPath: item.path)) != nil {
                        try files.removeItem(at: item)
                        continue
                    }
                    if name == "active-wrapp.lock" {
                        try files.removeItem(at: item)
                        continue
                    }
                    let new = store.appendingPathComponent(name)
                    if files.fileExists(atPath: new.path) {
                        // Both: the one written last is the sign-in.
                        guard modified(item) > modified(new) else {
                            try files.removeItem(at: item)
                            continue
                        }
                        try files.removeItem(at: new)
                    }
                    try files.moveItem(at: item, to: new)
                }
                try files.removeItem(at: old)
                try files.createSymbolicLink(at: old, withDestinationURL: store)
                logger.notice("Moved \(old.path) into \(store.path), leaving a link")
            } else if !files.fileExists(atPath: old.path), (try? files.destinationOfSymbolicLink(atPath: old.path)) == nil {
                try files.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createSymbolicLink(at: old, withDestinationURL: store)
            }
            let lockLink = store.appendingPathComponent("active-wrapp.lock")
            if (try? files.destinationOfSymbolicLink(atPath: lockLink.path)) == nil {
                try files.createDirectory(at: roots.steamLock.deletingLastPathComponent(), withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
                if !files.fileExists(atPath: roots.steamLock.path) {
                    files.createFile(atPath: roots.steamLock.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                try? files.removeItem(at: lockLink)
                try files.createSymbolicLink(at: lockLink, withDestinationURL: roots.steamLock)
            }
        } catch {
            logger.error("Couldn't move Steam's sign-in from \(old.path) into \(store.path): \(error.localizedDescription)")
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// `old` moved to `new`, if it's there, isn't a link already, and
    /// `new` isn't; with `linkBack`, a link to `new` left at `old`.
    static func move(_ old: URL, to new: URL, linkBack: Bool) {
        let files = FileManager.default
        guard (try? files.destinationOfSymbolicLink(atPath: old.path)) == nil, files.fileExists(atPath: old.path) else { return }
        do {
            guard !files.fileExists(atPath: new.path) else {
                logger.warning("Not moving \(old.path): \(new.path) is there already")
                return
            }
            try files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try files.moveItem(at: old, to: new)
            if linkBack { try files.createSymbolicLink(at: old, withDestinationURL: new) }
            logger.notice("Moved \(old.path) to \(new.path)\(linkBack ? ", leaving a link" : "")")
        } catch {
            logger.error("Couldn't move \(old.path) to \(new.path): \(error.localizedDescription)")
        }
    }
}
