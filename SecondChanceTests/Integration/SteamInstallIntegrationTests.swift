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
        let outcome = GameOutcome(slug: label ?? game.id, source: "steam", progress: Self.progress)
        defer { outcome.finish() }

        if !LoadGate.ignoringLoad, let reading = await LoadGate.overloadedReading() {
            Self.progress?.write(["event": "load", "message": "\(reading)"])
            outcome.overloaded = true
            Issue.record("The Mac is too busy to test \(game.id) fairly: \(reading)")
            return
        }

        // As in the disk suite: nothing can come to the front, so don't build.
        if let reason = ScreenState.blockedReason() {
            outcome.locked = true
            Issue.record("Not testing \(game.id): \(reason), so the game couldn't come to the front")
            return
        }

        if let owned = Self.ownedSlugs.withLock({ $0 }), !owned.contains(game.id) {
            outcome.skipped = "The Steam account doesn't own \(game.title) (checked by an earlier build in this run)"
            return
        }

        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-steam-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let recorder = RecordingEventSubscriber()
        await recorder.subscribe(to: EventBus.app)
        defer { Task { await recorder.unsubscribe(from: EventBus.app) } }
        outcome.phase("building")
        await Self.progress?.subscribe(to: EventBus.app)

        let logStart = LogStore.shared.nextSequence
        defer {
            LogStore.shared.flush()
            let lines = LogStore.shared.snapshot().entries.filter { $0.seq >= logStart }.map { LogFormatter.full(entry: $0) }
            if !lines.isEmpty {
                Attachment.record(Data((lines.joined(separator: "\n") + "\n").utf8), named: "secondchance-steam-\(game.id).txt")
            }
        }

        let viewModel = await MainActor.run {
            WrappBuildViewModel(makeInput: { WrappBuildInput(steamGame: game.id, launchMode: launchMode, outputDir: outputDir, viewModel: $0) })
        }
        Task { await MainActor.run { Task { await viewModel.buildFromSteam() } } }
        // A backstop only: the build times out Steam's sign-in and download itself.
        let succeeded = await recorder.waitForCompletion(timeout: 3000)
        Attachment.record(Data(recorder.events.map { "\($0)" }.joined(separator: "\n").utf8), named: "steam-events-\(game.id).txt")
        if let owned = recorder.steamGamesOwned {
            Self.ownedSlugs.withLock { $0 = Set(owned.map(\.id)) }
        }

        if case .steamGameNotOwned = recorder.failedError {
            outcome.skipped = "The Steam account doesn't own \(game.title)"
            return
        }
        outcome.expect(succeeded, "The Steam build did not complete")
        try #require(recorder.failedError == nil, "The Steam build failed: \(String(describing: recorder.failedError))")

        let engine = game.steamEngine(launchMode: launchMode)
        outcome.expect(recorder.detectedGame?.id == game.id, "Built \(recorder.detectedGame?.id ?? "nil"), not \(game.id)")
        outcome.expect(recorder.routedEngine == engine, "Engine \(String(describing: recorder.routedEngine)), expected \(engine)")
        let expectedExe = Self.expectedExePath(game, engine: engine)
        outcome.expect(recorder.detectedExePath == expectedExe, "Exe \(recorder.detectedExePath ?? "nil"), expected \(expectedExe ?? "nil")")
        for patch in recorder.failedPatches {
            outcome.expect(false, "Patch \(patch.id) failed: \(patch.message)")
        }
        outcome.expect(recorder.signedWrapp != nil, "signed event not emitted")
        let wrapp = try #require(recorder.completedWrapp, "completed event not emitted")

        // The build ran Steam signed in inside this wrapp; none of that may ship.
        let prefix = wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        for file in SteamSessionStore.files {
            outcome.expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(file).path), "\(file) shipped in the wrapp")
        }
        let userReg = (try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)) ?? ""
        outcome.expect(!userReg.contains("\"\(SteamSessionStore.registryValue)\"="), "\(SteamSessionStore.registryValue) shipped in the wrapp")
        outcome.expect(try WrappInfo.gameSlug(at: wrapp) == game.id, "Wrapp GameSlug isn't \(game.id)")

        guard WrappInfo.wrappPuppeteerBundle() != nil else {
            Attachment.record("WrappPuppeteer not built — skipped the launch", named: "launch-skipped-\(game.id).txt")
            outcome.completed = true
            return
        }
        outcome.phase("launching")
        // Steam starts and signs in before the game does.
        let exitCode = try await AppPuppetRunner.run(wrappURL: wrapp, game: game, timeout: 300)
        outcome.puppeteerExit = exitCode
        outcome.expect(exitCode == 0, "WrappPuppeteer exited \(exitCode)")
        outcome.completed = true
    }
}
