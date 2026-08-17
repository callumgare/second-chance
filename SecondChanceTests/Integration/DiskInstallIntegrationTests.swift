//
//  DiskInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Per-game integration tests for the disk install flow. These exercise the
//  REAL wrapper creation process (real Wine/ScummVM install, real file
//  detection) for each of the 33 Nancy Drew games, and assert the intermediate
//  results via the event bus.
//
//  REQUIREMENTS:
//    - Real installer ISOs must be present in `installers/<slug>/disk-1.iso`.
//      These are gitignored (too large for git) so tests auto-disable when
//      absent via `.disabled(if: !InstallersPresent.check())`.
//    - Tests are SLOW (minutes per game — real Wine install). Run deliberately:
//        xcodebuild test -scheme SecondChance -only-testing:SecondChanceTests/DiskInstallIntegrationTests
//    - Tests are SERIALIZED (.serialized) to avoid concurrent Wine prefixes.
//
//  What these tests verify that test-games.sh does not:
//    - The detected game slug matches the expected game
//    - The engine routing (wine vs scummvm) is correct
//    - The detected game exe path matches internalGameExePath from GameInfoProvider
//    - The wrapper's Info.plist contains the correct exe path after configuration
//    - The full event sequence is emitted in the expected order

import Testing
import Foundation
@testable import SecondChance

@Suite(
    "Disk install — per game",
    .serialized,
    .disabled(if: !InstallersPresent.check(), "No installer ISOs found in installers/")
)
struct DiskInstallIntegrationTests {

    /// A unique temp directory for each test invocation, so concurrent (if ever
    /// enabled) or repeated runs don't collide.
    private func makeOutputDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("sc-integration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Clean up the temp directory after the test.
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Per-game parameterized test

    @Test(
        "Wrapper creation produces correct intermediate results for each game",
        arguments: TestGameFilter.selectedGames
    )
    func wrapperCreationForGame(game: GameInfo) async throws {
        // SKIP_BUILD=1 (via --test-existing-wrapper): skip the install and use a
        // pre-existing wrapper from built-apps/ if present. Useful for iterating
        // on the GamePuppeteer test without waiting for a full Wine install.
        let skipBuild = ProcessInfo.processInfo.environment["SKIP_BUILD"] == "1"
        let builtAppsDir = TestPaths.repoRoot.appendingPathComponent("built-apps")
        let prebuiltWrapper = builtAppsDir.appendingPathComponent("Nancy Drew - \(game.title).app")
        let usingPrebuiltWrapper = skipBuild && FileManager.default.fileExists(atPath: prebuiltWrapper.path)

        let wrapperPath: URL
        var builtOutputDir: URL? = nil  // cleaned up after GamePuppeteer, not before

        if usingPrebuiltWrapper {
            wrapperPath = prebuiltWrapper
        } else {
            // ── E2E install via the real UI ───────────────────────────────────
            let disk1 = try #require(
                InstallerPaths.diskISO(for: game, diskNumber: 1),
                "disk-1.iso not found for \(game.id) at \(TestPaths.installersDir.path)/\(game.id)/"
            )
            let disk2 = InstallerPaths.diskISO(for: game, diskNumber: 2)

            if game.diskCount > 1 {
                #expect(disk2 != nil, "Game \(game.id) requires \(game.diskCount) disks but disk-2.iso not found")
            }

            let outputDir = makeOutputDir()
            builtOutputDir = outputDir

            // Pre-configure disk paths so WrappBuildInput bypasses NSOpenPanel.
            PreconfiguredPaths.disk1 = disk1
            PreconfiguredPaths.disk2 = disk2
            PreconfiguredPaths.outputDir = outputDir
            defer { PreconfiguredPaths.clear() }  // dir cleanup deferred until after GamePuppeteer

            let recorder = RecordingEventSubscriber()
            await recorder.subscribe(to: EventBus.app)
            defer { Task { await recorder.unsubscribe(from: EventBus.app) } }

            // Capture PID + start time to collect os.Logger output after the install.
            let logPid = ProcessInfo.processInfo.processIdentifier
            let logStart = Date()
            defer {
                // Wait for os.Logger to flush entries to the persistent store before querying.
                Thread.sleep(forTimeInterval: 2.0)
                let logData = SystemLogReader.fetch(pid: logPid, since: logStart)
                if !logData.isEmpty {
                    Attachment.record(logData, named: "secondchance-install-\(game.id).txt")
                }
            }

            // Fire installFromDisk() as a detached task so waitForCompletion() can run concurrently.
            let viewModel = await MainActor.run { InstallationViewModel() }
            Task { await MainActor.run { Task { await viewModel.installFromDisk() } } }

            let succeeded = await recorder.waitForCompletion(timeout: 600)

            // Attach event trace for debugging.
            let eventTrace = recorder.events.map { "\($0)" }.joined(separator: "\n")
            Attachment.record(Data(eventTrace.utf8), named: "install-events-\(game.id).txt")

            #expect(succeeded, "Installation did not complete within timeout")
            try #require(recorder.failedError == nil, "Installation failed: \(String(describing: recorder.failedError))")

            // ── Per-step assertions ───────────────────────────────────────────

            #expect(recorder.detectedGame?.id == game.id,
                    "Detected game \(recorder.detectedGame?.id ?? "nil") but expected \(game.id)")
            #expect(recorder.routedEngine == game.gameEngine,
                    "Routed engine \(String(describing: recorder.routedEngine)) but expected \(game.gameEngine)")

            if let expectedExe = game.internalGameExePath {
                #expect(recorder.detectedExePath == expectedExe,
                        "Detected exe path \(recorder.detectedExePath ?? "nil") but expected \(expectedExe)")
            }

            #expect(recorder.configuredWrapper != nil, "wrapperConfigured event not emitted")
            #expect(recorder.signedWrapper != nil, "signed event not emitted")
            #expect(recorder.completedWrapper != nil, "completed event not emitted")

            if let expectedExe = game.internalGameExePath {
                let plistExe = try WrapperInfo.gameExePath(at: outputDir.appendingPathComponent("Nancy Drew - \(game.title).app"))
                #expect(plistExe == expectedExe,
                        "Wrapper plist GameExePath \(plistExe ?? "nil") ≠ \(expectedExe)")
            }

            let plistSlug = try WrapperInfo.gameSlug(at: outputDir.appendingPathComponent("Nancy Drew - \(game.title).app"))
            #expect(plistSlug == game.id, "Wrapper plist GameSlug \(plistSlug ?? "nil") ≠ \(game.id)")

            // Event ordering.
            let kinds = recorder.events.map { "\($0)" }
            if let a = kinds.firstIndex(where: { $0.hasPrefix("gameDetected") }),
               let b = kinds.firstIndex(where: { $0.hasPrefix("engineRouted") }) {
                #expect(a < b, "gameDetected must precede engineRouted")
            }

            wrapperPath = recorder.completedWrapper ?? outputDir.appendingPathComponent("Nancy Drew - \(game.title).app")
        }

        // ── Launch & quit via GamePuppeteer ──────────────────────────────────

        guard WrapperInfo.gamePuppeteerBundle() != nil else {
            Attachment.record(Data("GamePuppeteer.app not found — skipping launch test".utf8),
                              named: "gamepuppeteer-skipped.txt")
            return
        }

        let exitCode = try await GamePuppetRunner.run(wrapperURL: wrapperPath, game: game)

        // Clean up the built wrapper now that GamePuppeteer is done with it.
        if let dir = builtOutputDir { cleanup(dir) }

        // 0 = clean quit
        #expect(exitCode == 0,
                "GamePuppeteer exited with \(exitCode) for \(game.id)")
    }
}
