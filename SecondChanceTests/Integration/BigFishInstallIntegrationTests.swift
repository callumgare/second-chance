//
//  BigFishInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Each game Big Fish Games sells built through Big Fish's Game Manager and
//  launched for real: the Big Fish counterpart of SteamInstallIntegrationTests.
//  Two suites, as there are two ways a headless build can get a game there:
//
//  - owned: signed in with the test account (`BIG_FISH_EMAIL` and
//    `BIG_FISH_PASSWORD`, which `sc` passes from `.env`); a game the account
//    doesn't own is skipped, not failed.
//  - trial: signed out, the game's free trial, so every game Big Fish sells
//    can be tested. Each build's prefix is new, so each gets a full 60
//    minutes, and the launch only goes as far as the menu.
//
//  Run with `sc test integration --source big-fish [<slug>…]` or
//  `--source big-fish-trial`. Both download every game they test.

import Foundation
import os
import Testing
@testable import SecondChance
@testable import SecondChanceKit
import GameCatalog

@Suite(
    "Big Fish install — per game (owned)",
    .enabled(if: BigFishIntegration.testAccountEmail != nil, "Set BIG_FISH_EMAIL and BIG_FISH_PASSWORD (.env) to test owned Big Fish games")
)
struct BigFishOwnedInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    static var selectedGames: [GameInfo] { TestGameFilter.selectedGames.filter(\.isOnBigFish) }

    /// The slugs the account owns, from the first build that signed in, so
    /// the rest of the run skips the others without signing in again for
    /// each, as the Steam suite does.
    private static let ownedSlugs = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    @Test("Each game the Big Fish account owns builds from Big Fish and launches", arguments: selectedGames)
    func game(_ game: GameInfo) async throws {
        // One owned game at a time (IntegrationStages.bigFish): every build
        // signs in to the one account and out again. Other sources' games,
        // and the trials, build alongside.
        try await IntegrationStages.bigFish.withLock {
            try await buildAndLaunch(game)
        }
    }

    private func buildAndLaunch(_ game: GameInfo) async throws {
        let run = IntegrationGameRun(game: game, label: game.id, source: "big-fish", progress: Self.progress)
        try await run.run { outcome in
            if let owned = Self.ownedSlugs.withLock({ $0 }), !owned.contains(game.id) {
                outcome.skipped = "The Big Fish account doesn't own \(game.title) (checked by an earlier build in this run)"
                return nil
            }
            guard await BigFishIntegration.fetchGameManagerInstaller(outcome) else { return nil }
            return IntegrationGameRun.Build(
                expectedEngine: game.gameEngine,
                makeInput: { outputDir, viewModel in
                    WrappBuildInput(bigFishGame: game.id, trial: false, outputDir: outputDir, viewModel: viewModel)
                },
                start: { await $0.build(from: .bigFish) }
            )
        } afterBuild: { recorder, outcome in
            if let owned = recorder.bigFishGamesOwned {
                Self.ownedSlugs.withLock { $0 = Set(owned.map(\.id)) }
            }
            if case .bigFishGameNotOwned = recorder.failedError {
                outcome.skipped = "The Big Fish account doesn't own \(game.title)"
                return false
            }
            return true
        } check: { recorder, wrapp, outcome in
            // The build signed in with the test account, read its library and
            // had the Game Manager get the game.
            for marker in BigFishIntegration.ownedLogMarkers {
                outcome.expect(outcome.buildLog.contains { $0.contains(marker) }, "The build's log has no \"\(marker)\" line")
            }
            outcome.expect(recorder.bigFishGamesOwned?.contains { $0.id == game.id } == true,
                           "The bigFishGamesOwned event didn't list \(game.id)")
            BigFishIntegration.checkSettings(of: wrapp, game: game, trial: false, outcome: outcome)

            // The build ran the Game Manager signed in inside this wrapp; none
            // of that may ship. The address is the part that can be looked
            // for: it's never shown, only whether and where it was found.
            if let email = BigFishIntegration.testAccountEmail {
                let prefix = WrappLayout(app: wrapp).prefix
                let found = await Blocking.run { BigFishIntegration.files(in: prefix, mentioning: email) }
                outcome.expect(found.isEmpty, "The test account's email address shipped in the wrapp, in \(found.joined(separator: ", "))")
            }
        }
    }
}

@Suite("Big Fish install — per game (trial)")
struct BigFishTrialInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    static var selectedGames: [GameInfo] { TestGameFilter.selectedGames.filter(\.isOnBigFish) }

    /// Trials build side by side, as other sources' games do: each has a
    /// prefix and a Game Manager of its own, and none signs in.
    @Test("Each game's Big Fish free trial builds and launches", arguments: selectedGames)
    func game(_ game: GameInfo) async throws {
        let run = IntegrationGameRun(game: game, label: game.id, source: "big-fish-trial", progress: Self.progress)
        try await run.run { outcome in
            guard await BigFishIntegration.fetchGameManagerInstaller(outcome) else { return nil }
            return IntegrationGameRun.Build(
                expectedEngine: game.gameEngine,
                makeInput: { outputDir, viewModel in
                    WrappBuildInput(bigFishGame: game.id, trial: true, outputDir: outputDir, viewModel: viewModel)
                },
                start: { await $0.build(from: .bigFish) }
            )
        } check: { recorder, wrapp, outcome in
            outcome.expect(recorder.bigFishGamesOwned == nil, "A trial build read an account's library")
            outcome.expect(outcome.buildLog.contains { $0.contains(BigFishIntegration.installedMarker) },
                           "The build's log has no \"\(BigFishIntegration.installedMarker)\" line")
            BigFishIntegration.checkSettings(of: wrapp, game: game, trial: true, outcome: outcome)
        }
    }
}

/// What both Big Fish suites share.
enum BigFishIntegration {
    /// The test account's address, when its sign-in is in the test's
    /// environment (`sc` passes `.env`'s as `TEST_RUNNER_BIG_FISH_*`).
    nonisolated static var testAccountEmail: String? {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["BIG_FISH_EMAIL"], !email.isEmpty,
              let password = env["BIG_FISH_PASSWORD"], !password.isEmpty else { return nil }
        return email
    }

    /// What `BigFishWrappBuilder` logs once the Game Manager has the game
    /// installed and activated.
    static let installedMarker = "is installed and activated in"

    /// What an owned build's log says as it signs in, reads the account's
    /// library and gets the game.
    static let ownedLogMarkers = [
        "Signing in to the Game Manager with the test harness's account",
        "The Big Fish account owns",
        installedMarker,
    ]

    /// Download the Game Manager's installer into the caches, once: builds
    /// side by side would otherwise each download it and race to save it.
    /// False, with the failure recorded, when it can't be had.
    static func fetchGameManagerInstaller(_ outcome: GameOutcome) async -> Bool {
        do {
            try await IntegrationStages.bigFishInstaller.withLock {
                _ = try await BigFishWrappPreparer.gameManagerInstaller()
            }
            return true
        } catch {
            outcome.expect(false, "Couldn't download Big Fish's Game Manager installer: \(error)")
            return false
        }
    }

    /// The wrapp records where its game came from and how it starts: through
    /// the game's `LaunchGame.bfg` for a Wine game, ScummVM's own way for the
    /// others; and the English edition for a trial.
    static func checkSettings(of wrapp: URL, game: GameInfo, trial: Bool, outcome: GameOutcome) {
        guard let settings = WrappInfo.settings(at: wrapp) else {
            outcome.expect(false, "The wrapp has no settings it can read")
            return
        }
        outcome.expect(settings.source == .bigFish, "The wrapp's source is \(settings.source?.rawValue ?? "nil"), expected big-fish")
        let sku = settings.bigFishSKU.flatMap(BigFishSKU.init)
        outcome.expect(sku?.product == game.bigFishProduct,
                       "The wrapp's BigFishSKU is \(settings.bigFishSKU ?? "nil"), expected product \(game.bigFishProduct.map(String.init) ?? "nil")")
        if trial {
            outcome.expect(sku?.language == BigFishSKU.english, "The trial isn't the English edition: \(settings.bigFishSKU ?? "nil")")
            outcome.expect(settings.bigFishTrial == true, "The wrapp's BigFishTrial isn't true")
        } else {
            outcome.expect(settings.bigFishTrial != true, "The wrapp of an owned game says it's a trial")
        }
        if game.gameEngine == .scummvm {
            outcome.expect(settings.bigFishLaunchFile == nil, "A ScummVM wrapp has a BigFishLaunchFile")
        } else if let launchFile = settings.bigFishLaunchFile {
            outcome.expect(launchFile.lowercased().hasSuffix("/launchgame.bfg"), "BigFishLaunchFile is \(launchFile), not a LaunchGame.bfg")
            let onDisk = WrappLayout(app: wrapp).onDriveC(launchFile)
            outcome.expect(FileManager.default.fileExists(atPath: onDisk.path), "The wrapp's \(launchFile) isn't in it")
        } else {
            outcome.expect(false, "The wrapp has no BigFishLaunchFile")
        }
    }

    // MARK: - No sign-in left behind

    /// Larger files are the game's and the download's: archives, video and
    /// the like, not where a sign-in is kept.
    nonisolated static let largestFileSearched = 32_000_000

    /// Where in a prefix the Game Manager could keep a sign-in: the
    /// registry, its download cache and data, and the Windows user's folders
    /// (Chromium's cookies and storage).
    nonisolated static let searchedPaths = [
        "user.reg", "system.reg", "userdef.reg",
        "drive_c/BigFishCache", "drive_c/ProgramData/Big Fish", "drive_c/users",
    ]

    /// The files under `prefix`'s `searchedPaths` holding `text`, as it is,
    /// lower-cased, URL-encoded or in UTF-16 (the registry's and Windows's
    /// own), as paths from the prefix.
    nonisolated static func files(in prefix: URL, mentioning text: String) -> [String] {
        var forms = Set([text, text.lowercased()])
        for form in forms { forms.insert(form.replacingOccurrences(of: "@", with: "%40")) }
        let needles = forms.flatMap { [Data($0.utf8), $0.data(using: .utf16LittleEndian)].compactMap { $0 } }

        var found: [String] = []
        for path in searchedPaths {
            let root = prefix.appendingPathComponent(path)
            var files: [URL] = []
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                while let url = walk?.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if values?.isRegularFile == true, (values?.fileSize ?? 0) <= largestFileSearched { files.append(url) }
                }
            } else {
                files = [root]
            }
            for file in files {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                      needles.contains(where: { data.range(of: $0) != nil }) else { continue }
                found.append(String(file.path.dropFirst(prefix.path.count + 1)))
            }
        }
        return found
    }
}
