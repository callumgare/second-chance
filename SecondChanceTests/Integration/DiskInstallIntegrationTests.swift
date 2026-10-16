//
//  DiskInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Per-game integration tests for the disk install flow. These exercise the
//  REAL wrapp creation process (real Wine/ScummVM install, real file
//  detection) for each of the 33 Nancy Drew games, and assert the intermediate
//  results via the event bus.
//
//  REQUIREMENTS:
//    - Real installer ISOs must be present in `installers/<slug>/disk-1.iso`.
//      These are gitignored (too large for git) so tests auto-disable when
//      absent via `.disabled(if: !InstallersPresent.shouldRun())` — except
//      under `sc test integration`, which sets REQUIRE_INSTALLERS so a
//      missing ISO fails instead.
//    - Tests are SLOW (minutes per game — real Wine install). Run deliberately:
//        ./sc test integration <slug>
//    - Tests are SERIALIZED (.serialized) to avoid concurrent Wine prefixes.
//
//  What these tests verify that test-games.sh does not:
//    - The detected game slug matches the expected game
//    - The engine routing (wine vs scummvm) is correct
//    - The detected game exe path matches internalGameExePath from GameInfoProvider
//    - The wrapp's Info.plist contains the correct exe path after configuration
//    - The full event sequence is emitted in the expected order

import Testing
import Foundation
@testable import SecondChance

@Suite(
    "Disk install — per game",
    .serialized,
    .disabled(if: !InstallersPresent.shouldRun(), "No installer ISOs found in installers/")
)
struct DiskInstallIntegrationTests {

    /// Where `sc test integration` follows progress (`TEST_RUNNER_PROGRESS_PATH`).
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

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

    // MARK: - Game filter

    @Test("Every requested game slug names a known game")
    func requestedGamesExist() {
        #expect(
            TestGameFilter.unknownSlugs.isEmpty,
            "Unknown game slug(s): \(TestGameFilter.unknownSlugs.joined(separator: ", ")) — see GameInfoProvider for valid ids"
        )
    }

    // MARK: - Per-game parameterized test

    @Test(
        "Wrapp creation produces correct intermediate results for each game",
        arguments: TestGameFilter.selectedGames
    )
    func wrappCreationForGame(game: GameInfo) async throws {
        // Per-game progress for `sc test integration`'s live display. The
        // finished line's result agrees with this test's: any failed
        // expectation or thrown error makes it "failed".
        let outcome = GameOutcome(slug: game.id, progress: Self.progress)
        defer { outcome.finish() }

        // SKIP_BUILD=1 (`sc test integration --refresh-wrapp template|skip`):
        // skip the install and use a pre-existing wrapp from the wrapps dir if
        // present. Useful for iterating on the WrappPuppeteer test without
        // waiting for a full Wine install.
        let skipBuild = ProcessInfo.processInfo.environment["SKIP_BUILD"] == "1"
        let builtAppsDir = TestPaths.wrappsDir
        let prebuiltWrapp = builtAppsDir.appendingPathComponent("Nancy Drew - \(game.title).app")
        let usingPrebuiltWrapp = skipBuild && FileManager.default.fileExists(atPath: prebuiltWrapp.path)

        let wrappPath: URL
        var builtOutputDir: URL? = nil  // cleaned up after WrappPuppeteer, not before

        if usingPrebuiltWrapp {
            wrappPath = prebuiltWrapp
        } else {
            // ── E2E install via the real UI ───────────────────────────────────
            let disk1 = try #require(
                InstallerPaths.diskISO(for: game, diskNumber: 1),
                "disk-1.iso not found for \(game.id) at \(TestPaths.installersDir.path)/\(game.id)/"
            )
            let disk2 = InstallerPaths.diskISO(for: game, diskNumber: 2)

            if game.diskCount > 1 {
                outcome.expect(disk2 != nil, "Game \(game.id) requires \(game.diskCount) disks but disk-2.iso not found")
            }

            let outputDir = makeOutputDir()
            builtOutputDir = outputDir

            let recorder = RecordingEventSubscriber()
            await recorder.subscribe(to: EventBus.app)
            defer { Task { await recorder.unsubscribe(from: EventBus.app) } }
            outcome.phase("building")
            // Subscribes once for the whole run; later games reuse it.
            await Self.progress?.subscribe(to: EventBus.app)

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

            // Drive the real entry point, with a fixed-path input injected so
            // WrappBuildInput takes its env-var branch and no panel appears.
            // Fire buildFromDisk() as a detached task so waitForCompletion()
            // can run concurrently.
            let viewModel = await MainActor.run {
                WrappBuildViewModel(makeInput: {
                    WrappBuildInput(
                        disk1: disk1,
                        disk2: disk2,
                        outputDir: outputDir,
                        viewModel: $0
                    )
                })
            }
            Task { await MainActor.run { Task { await viewModel.buildFromDisk() } } }

            let succeeded = await recorder.waitForCompletion(timeout: 600)

            // Attach event trace for debugging.
            let eventTrace = recorder.events.map { "\($0)" }.joined(separator: "\n")
            Attachment.record(Data(eventTrace.utf8), named: "install-events-\(game.id).txt")

            outcome.expect(succeeded, "Installation did not complete within timeout")
            try #require(recorder.failedError == nil, "Installation failed: \(String(describing: recorder.failedError))")

            // ── Per-step assertions ───────────────────────────────────────────

            outcome.expect(recorder.detectedGame?.id == game.id,
                    "Detected game \(recorder.detectedGame?.id ?? "nil") but expected \(game.id)")
            outcome.expect(recorder.routedEngine == game.gameEngine,
                    "Routed engine \(String(describing: recorder.routedEngine)) but expected \(game.gameEngine)")

            if let expectedExe = game.internalGameExePath {
                outcome.expect(recorder.detectedExePath == expectedExe,
                        "Detected exe path \(recorder.detectedExePath ?? "nil") but expected \(expectedExe)")
            }

            outcome.expect(recorder.configuredWrapp != nil, "wrappConfigured event not emitted")
            outcome.expect(recorder.signedWrapp != nil, "signed event not emitted")
            outcome.expect(recorder.completedWrapp != nil, "completed event not emitted")

            if let expectedExe = game.internalGameExePath {
                let plistExe = try WrappInfo.gameExePath(at: outputDir.appendingPathComponent("Nancy Drew - \(game.title).app"))
                outcome.expect(plistExe == expectedExe,
                        "Wrapp plist GameExePath \(plistExe ?? "nil") ≠ \(expectedExe)")
            }

            let plistSlug = try WrappInfo.gameSlug(at: outputDir.appendingPathComponent("Nancy Drew - \(game.title).app"))
            outcome.expect(plistSlug == game.id, "Wrapp plist GameSlug \(plistSlug ?? "nil") ≠ \(game.id)")

            // Event ordering.
            let kinds = recorder.events.map { "\($0)" }
            if let a = kinds.firstIndex(where: { $0.hasPrefix("gameDetected") }),
               let b = kinds.firstIndex(where: { $0.hasPrefix("engineRouted") }) {
                outcome.expect(a < b, "gameDetected must precede engineRouted")
            }

            wrappPath = recorder.completedWrapp ?? outputDir.appendingPathComponent("Nancy Drew - \(game.title).app")
        }

        // ── Launch & quit via WrappPuppeteer ──────────────────────────────────

        guard WrappInfo.wrappPuppeteerBundle() != nil else {
            Attachment.record(Data("WrappPuppeteer.app not found — skipping launch test".utf8),
                              named: "wrapp-puppeteer-skipped.txt")
            outcome.completed = true
            return
        }

        outcome.phase("launching")
        let exitCode = try await AppPuppetRunner.run(wrappURL: wrappPath, game: game)
        outcome.puppeteerExit = exitCode

        // Clean up the built wrapp now that WrappPuppeteer is done with it.
        if let dir = builtOutputDir { cleanup(dir) }

        // 0 = clean quit
        outcome.expect(exitCode == 0,
                "WrappPuppeteer exited with \(exitCode) for \(game.id)")
        outcome.completed = true

    }
}

/// One game's result as `sc test integration` shows it, written to the
/// progress stream when the test ends. Expectations go through `expect` so a
/// failed one is counted here as well as recorded as an issue.
final class GameOutcome: @unchecked Sendable {
    let slug: String
    let progress: ProgressFileWriter?
    let started = Date()
    /// Set once the test has run to its end without throwing.
    var completed = false
    var puppeteerExit: Int32?
    private var failedExpectations = 0

    init(slug: String, progress: ProgressFileWriter?) {
        self.slug = slug
        self.progress = progress
        progress?.write(["event": "game", "slug": slug, "phase": "started"])
    }

    func expect(_ condition: Bool, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, comment, sourceLocation: sourceLocation)
        if !condition { failedExpectations += 1 }
    }

    func phase(_ phase: String) {
        progress?.write(["event": "game", "slug": slug, "phase": phase])
    }

    func finish() {
        let result: String
        if let code = puppeteerExit, (3...5).contains(code) {
            // WrappPuppeteer is missing a TCC grant — not a regression.
            result = "permission"
        } else {
            result = completed && failedExpectations == 0 ? "passed" : "failed"
        }
        var record: [String: Any] = [
            "event": "game", "slug": slug, "phase": "finished", "result": result,
            "seconds": Date().timeIntervalSince(started),
        ]
        if let puppeteerExit { record["puppeteerExit"] = Int(puppeteerExit) }
        progress?.write(record)
    }
}
