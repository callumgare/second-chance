//
//  AppMigrationsTests.swift
//  SecondChanceTests
//
//  What Second Chance moves into the stores as it starts, and the links it
//  leaves for 1.1.0's Steam apps.

import Foundation
import Testing
@testable import SecondChance

struct AppMigrationsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("migrations-\(UUID().uuidString)")
    var roots: AppMigrations.Roots {
        AppMigrations.Roots(appSupport: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"))
    }

    private func make(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("1.1.0's Steam folder moves into the sign-in store and becomes a link to it, which a 1.1.0 app saves through")
    func steamMovesAndLinksBack() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("support/SecondChance/Steam/session/local.vdf", "token")
        try make("support/SecondChance/Steam/session.lock", "")
        try make("support/SecondChance/Steam/active-wrapp.lock", "42\nau.example.game\n")
        try make("support/SecondChance/BigFish/sign-in.reg", "reg")
        try make("caches/SecondChance/steam-client/Steam/steam.exe", "MZ")
        AppMigrations.run(roots)

        let old = root.appendingPathComponent("support/SecondChance/Steam")
        let files = FileManager.default
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "token")
        #expect(try files.destinationOfSymbolicLink(atPath: old.path) == roots.steamSignIn.path)
        // The old path still reads the session, and locks the same files.
        #expect(try String(contentsOf: old.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "token")
        #expect(try files.destinationOfSymbolicLink(atPath: roots.steamSignIn.appendingPathComponent("active-wrapp.lock").path)
            == roots.steamLock.path)
        #expect(files.fileExists(atPath: roots.steamLock.path))
        #expect(files.fileExists(atPath: roots.steamSignIn.appendingPathComponent("session.lock").path))
        // A 1.1.0 app's save: a staged session swapped in.
        try make("support/SecondChance/Steam/session.new/local.vdf", "refreshed")
        _ = try files.replaceItemAt(old.appendingPathComponent("session"), withItemAt: old.appendingPathComponent("session.new"))
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "refreshed")
        // Big Fish's and the client: moved, no link.
        #expect(files.fileExists(atPath: roots.bigFishSignIn.appendingPathComponent("sign-in.reg").path))
        #expect(!files.fileExists(atPath: root.appendingPathComponent("support/SecondChance/BigFish/sign-in.reg").path))
        #expect(files.fileExists(atPath: roots.steamClient.appendingPathComponent("Steam/steam.exe").path))

        // A second start leaves everything as it is.
        AppMigrations.run(roots)
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "refreshed")
    }

    @Test("With a session in both places, the one written last is kept, and the old folder still becomes a link")
    func newerSessionWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("support/SecondChance/stores/steam/sign-in/session/local.vdf", "store's")
        try make("support/SecondChance/Steam/session/local.vdf", "old app's")
        let old = root.appendingPathComponent("support/SecondChance/Steam")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: old.appendingPathComponent("session").path)
        AppMigrations.run(roots)
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "old app's")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == roots.steamSignIn.path)
    }

    @Test("A folder an earlier build migrated item by item is made a link too")
    func itemLinksBecomeAFolderLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("support/SecondChance/stores/steam/sign-in/session/local.vdf", "token")
        let old = root.appendingPathComponent("support/SecondChance/Steam")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("session"),
                                                   withDestinationURL: roots.steamSignIn.appendingPathComponent("session"))
        AppMigrations.run(roots)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == roots.steamSignIn.path)
        #expect(try String(contentsOf: old.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "token")
    }
}
