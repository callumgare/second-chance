//
//  SteamInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Each game on Steam built from Steam and launched for real: the Steam
//  counterpart of DiskInstallIntegrationTests. Builds are headless, so they
//  can't sign in to Steam — the Mac needs a saved sign-in (build a Steam game
//  from the app once). A game the account doesn't own is skipped, not failed.
//
//  Run with `sc test integration --source steam [<slug>…]`. Downloads every
//  game it tests, so it is slow and, run often, could trip Steam's limits.

import Foundation
import os
import Testing
@testable import ProcessKit
@testable import SecondChance
import WrappBuilder
import WrappFormat
import WrappModules
@testable import SecondChanceKit
@testable import WineKit
import GameCatalog

@Suite("Steam install — per game",
       .enabled(if: SteamSessionStore().hasSession, "No saved Steam sign-in on this Mac: build a Steam game from the app once"))
struct SteamInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    static var selectedGames: [GameInfo] { TestGameFilter.selectedGames.filter(\.isOnSteam) }

    /// The slugs the account owns, from the first build that signed in. Each
    /// build signs in to Steam afresh, and signing in again and again just
    /// to learn a game isn't owned got the account's sign-ins stalled for an
    /// hour and a half partway through a full run.
    private static let ownedSlugs = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    @Test("Each game on Steam builds from Steam and launches", arguments: selectedGames)
    func game(_ game: GameInfo) async throws {
        // One Steam game at a time, built and launched (IntegrationStages.steam);
        // games from other sources build alongside. A DRM-free game is built
        // to launch directly, the default answer.
        try await IntegrationStages.steam.withLock {
            try await buildAndLaunch(game, launchMode: game.offersSteamLaunchChoice ? "direct" : nil)
        }
    }

    // MARK: - One game

    /// The engine and exe the game's Steam edition should give, as its plan
    /// says for `launchMode`: the program Steam starts or Wine does, where
    /// the bundle installs it, or ScummVM's data in the app.
    static func expected(_ game: GameInfo, launchMode: String?) throws -> (engine: GameInfo.GameEngine, exe: String) {
        let plan = try ShippedBundles.plan(forGame: game.id, edition: "steam", choices: launchMode.map { ["launch-mode": $0] } ?? [:])
        let launch = try #require(plan?.launch)
        let composition = Composition(launch: launch)
        let program = launch.options["steam.exe"] ?? launch.program
        let exe = composition.launcher == .scummvm ? "/SharedSupport/game" : String(program.dropFirst("wine:C:".count))
        return (composition.legacyEngine ?? .wine, exe)
    }

    private func buildAndLaunch(_ game: GameInfo, launchMode: String?, label: String? = nil) async throws {
        let (engine, expectedExe) = try Self.expected(game, launchMode: launchMode)
        let run = IntegrationGameRun(game: game, label: label ?? game.id, source: "steam", progress: Self.progress)
        try await run.run { outcome in
            if let owned = Self.ownedSlugs.withLock({ $0 }), !owned.contains(game.id) {
                outcome.skipped = "The Steam account doesn't own \(game.title) (checked by an earlier build in this run)"
                return nil
            }
            return IntegrationGameRun.Build(
                expectedEngine: engine,
                makeInput: { outputDir, viewModel in
                    WrappBuildInput(steamGame: game.id, launchMode: launchMode, outputDir: outputDir, viewModel: viewModel)
                },
                start: { await $0.build(from: .steam) }
            )
        } afterBuild: { recorder, outcome in
            if let owned = recorder.steamGamesOwned {
                Self.ownedSlugs.withLock { $0 = Set(owned.map(\.id)) }
            }
            if case .steamGameNotOwned = recorder.failedError {
                outcome.skipped = "The Steam account doesn't own \(game.title)"
                return false
            }
            return true
        } check: { recorder, wrapp, outcome in
            // How far Steam got is logged as it goes, so a stalled sign-in
            // can be followed in the log.
            for marker in [SteamSignInWatch.waitingMarker, SteamSignInWatch.signedInMarker] {
                outcome.expect(outcome.buildLog.contains { $0.contains(marker) }, "The build's log has no \"\(marker)\" line")
            }

            outcome.expect(recorder.detectedExePath == expectedExe, "Exe \(recorder.detectedExePath ?? "nil"), expected \(expectedExe)")

            // The build ran Steam signed in inside this wrapp; none of that may ship.
            let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
            for file in SteamSessionStore.files {
                outcome.expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(file).path), "\(file) shipped in the wrapp")
            }
            let userReg = (try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)) ?? ""
            outcome.expect(!userReg.contains("\"\(SteamSessionStore.registryValue)\"="), "\(SteamSessionStore.registryValue) shipped in the wrapp")
        }
    }
}
