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

    @Test("1.1.0's Steam session and locks move into the steam stores, each leaving a link a 1.1.0 app follows")
    func steamMovesAndLinksBack() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("support/SecondChance/Steam/session/local.vdf", "token")
        try make("support/SecondChance/Steam/session.lock", "")
        try make("support/SecondChance/Steam/active-wrapp.lock", "42\nau.example.game\n")
        try make("support/SecondChance/BigFish/sign-in.reg", "reg")
        try make("caches/SecondChance/steam-client/Steam/steam.exe", "MZ")
        AppMigrations.run(roots)

        let old = root.appendingPathComponent("support/SecondChance/Steam")
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "token")
        // The old path still reads the session, and locks the same file.
        #expect(try String(contentsOf: old.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "token")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.appendingPathComponent("active-wrapp.lock").path)
            == roots.steamLock.path)
        #expect(FileManager.default.fileExists(atPath: roots.steamSignIn.appendingPathComponent("session.lock").path))
        // Big Fish's and the client: moved, no link.
        #expect(FileManager.default.fileExists(atPath: roots.bigFishSignIn.appendingPathComponent("sign-in.reg").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("support/SecondChance/BigFish/sign-in.reg").path))
        #expect(FileManager.default.fileExists(atPath: roots.steamClient.appendingPathComponent("Steam/steam.exe").path))

        // A second start leaves everything as it is.
        AppMigrations.run(roots)
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "token")
    }

    @Test("Nothing is moved over what the store has already")
    func neverOverwrites() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make("support/SecondChance/Steam/session/local.vdf", "old")
        try make("support/SecondChance/stores/steam/sign-in/session/local.vdf", "new")
        AppMigrations.run(roots)
        #expect(try String(contentsOf: roots.steamSignIn.appendingPathComponent("session/local.vdf"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: root.appendingPathComponent("support/SecondChance/Steam/session/local.vdf"), encoding: .utf8) == "old")
    }
}
