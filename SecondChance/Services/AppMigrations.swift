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
        let old = roots.appSupport.appendingPathComponent("SecondChance/Steam", isDirectory: true)
        // Steam shipped in 1.1.0, whose apps keep using the old paths: each
        // is moved and a link left there, which a 1.1.0 app follows to the
        // same session, and to the same lock file, so an `flock` through the
        // link still excludes the new apps and builds.
        move(old.appendingPathComponent("session"), to: roots.steamSignIn.appendingPathComponent("session"), linkBack: true)
        move(old.appendingPathComponent("session.lock"), to: roots.steamSignIn.appendingPathComponent("session.lock"), linkBack: true)
        move(old.appendingPathComponent("active-wrapp.lock"), to: roots.steamLock, linkBack: true)
        // A cache, and nothing released reads it from elsewhere.
        move(roots.caches.appendingPathComponent("SecondChance/steam-client"), to: roots.steamClient, linkBack: false)
        // Big Fish's sign-in isn't released: moved, no link.
        move(roots.appSupport.appendingPathComponent("SecondChance/BigFish/sign-in.reg"),
             to: roots.bigFishSignIn.appendingPathComponent("sign-in.reg"), linkBack: false)
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
