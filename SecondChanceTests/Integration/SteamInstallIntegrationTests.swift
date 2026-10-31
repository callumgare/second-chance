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
@testable import SecondChance

@Suite("Steam install — per game", .serialized,
       .enabled(if: SteamSessionStore().hasSession, "No saved Steam sign-in on this Mac: build a Steam game from the app once"))
struct SteamInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    static var selectedGames: [GameInfo] { TestGameFilter.selectedGames.filter(\.isOnSteam) }

    /// The slugs the account owns, from the first build that signed in. Each
    /// build signs in to Steam afresh, and signing in again and again just
    /// to learn a game isn't owned got the account's sign-ins stalled for an
    /// hour and a half partway through a full run.
    private static let ownedSlugs = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    @Test("Each game on Steam builds from Steam and launches", .timeLimit(.minutes(60)), arguments: selectedGames)
    func game(_ game: GameInfo) async throws {
        // A DRM-free game is built to launch directly, the default answer.
        try await IntegrationSerial.shared.run {
            try await buildAndLaunch(game, launchMode: game.offersSteamLaunchChoice ? .direct : nil)
        }
    }

    // MARK: - One game

    /// Where the build should put the game's exe, from the game's Steam data
    /// and the engine its launch mode gives.
    static func expectedExePath(_ game: GameInfo, engine: GameInfo.GameEngine) -> String? {
        guard let installDir = game.steamInstallDir, let exe = game.steamExePath else { return nil }
        switch engine {
        case .scummvm: return "/Program Files (x86)/Nancy Drew/\(installDir)"
        case .wine: return "/Program Files (x86)/Nancy Drew/\(installDir)/\(exe)"
        case .wineSteam, .wineSteamSilent: return "/Program Files (x86)/Steam/steamapps/common/\(installDir)/\(exe)"
        }
    }

    private func buildAndLaunch(_ game: GameInfo, launchMode: GameInfo.SteamLaunchMode?, label: String? = nil) async throws {
        let engine = game.steamEngine(launchMode: launchMode)
        var run = IntegrationGameRun(game: game, label: label ?? game.id, source: "steam", progress: Self.progress)
        // Steam starts and signs in before the game does.
        run.launchTimeout = 300
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
                start: { await $0.buildFromSteam() }
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
            let expectedExe = Self.expectedExePath(game, engine: engine)
            outcome.expect(recorder.detectedExePath == expectedExe, "Exe \(recorder.detectedExePath ?? "nil"), expected \(expectedExe ?? "nil")")

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
