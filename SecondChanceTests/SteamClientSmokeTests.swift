//
//  SteamClientSmokeTests.swift
//  SecondChanceTests
//
//  The Steam client driven for real: restore a saved sign-in into a wrapp
//  whose Steam has never signed in, install a game, quit, save the session.
//  Off unless pointed at a wrapp — it needs a signed-in Steam account that
//  owns the game, and downloads it:
//
//    TEST_RUNNER_STEAM_SMOKE_WRAPP=<wrapp with Steam installed, signed out>
//    TEST_RUNNER_STEAM_SMOKE_STORE=<session store directory to use>
//    TEST_RUNNER_STEAM_SMOKE_SEED_PREFIX=<prefix signed in to save from first> (optional)
//    TEST_RUNNER_STEAM_SMOKE_APP=<app ID>:<install dir> (default: Message in a Haunted Mansion)

import Foundation
import Testing
@testable import SecondChance

private let environment = ProcessInfo.processInfo.environment

@Suite("Steam client (real Steam)", .serialized,
       .enabled(if: environment["STEAM_SMOKE_WRAPP"] != nil && environment["STEAM_SMOKE_STORE"] != nil,
                "Set TEST_RUNNER_STEAM_SMOKE_WRAPP and TEST_RUNNER_STEAM_SMOKE_STORE to run"))
struct SteamClientSmokeTests {
    @Test("A saved sign-in carries into a fresh Steam, which installs a game and saves the session again",
          .timeLimit(.minutes(20)))
    func restoreInstallSave() async throws {
        let wrapp = URL(fileURLWithPath: try #require(environment["STEAM_SMOKE_WRAPP"]))
        let store = SteamSessionStore(root: URL(fileURLWithPath: try #require(environment["STEAM_SMOKE_STORE"])))
        if let seed = environment["STEAM_SMOKE_SEED_PREFIX"] {
            let seeded = try store.capture(from: URL(fileURLWithPath: seed), signedIn: true)
            #expect(seeded == .saved || seeded == .unchanged || seeded == .storeIsNewer)
        }
        let app = (environment["STEAM_SMOKE_APP"] ?? "615770:Nancy Drew Message in a Haunted Mansion")
            .split(separator: ":", maxSplits: 1).map(String.init)
        let appID = try #require(Int(app[0]))
        let installDir = app[1]

        let client = SteamClient(wrappPath: wrapp)
        #expect(client.isInstalled)
        #expect(try await client.restoreLogin(from: store))
        try client.queueInstall(appID: appID, installDir: installDir)
        try await client.start(silent: true)

        var signedIn = false
        do {
            let login = await client.waitForLogin(timeout: 300)
            #expect(login == .signedIn)
            signedIn = login == .signedIn
            try #require(signedIn)
            #expect(try await client.ownedAppIDs(timeout: 60).contains(appID))

            let deadline = Date().addingTimeInterval(900)
            var phase = client.installPhase(appID: appID)
            while Date() < deadline, phase != .installed {
                if case .failed = phase { break }
                try await Task.sleep(for: .seconds(3))
                phase = client.installPhase(appID: appID)
            }
            #expect(phase == .installed)
            #expect(client.manifest(appID: appID)?.isFullyInstalled == true)
        } catch {
            await client.shutdown(timeout: 90)
            throw error
        }
        await client.shutdown(timeout: 90)
        #expect(!client.wine.isWineserverRunning())
        let saved = try client.saveLogin(to: store, signedIn: signedIn)
        #expect(saved == .saved || saved == .unchanged)
    }
}
