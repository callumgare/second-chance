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

    /// Clean up the temp directory after the test. A wrapp built from discs
    /// can hold read-only directories (a build before they were made writable,
    /// or one stopped partway), which `removeItem` can't delete; give the owner
    /// write permission and try once more, since each one left behind is
    /// gigabytes.
    private func cleanup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+w", url.path]
            do {
                try chmod.run()
                chmod.waitUntilExit()
                try FileManager.default.removeItem(at: url)
            } catch {
                Issue.record("Could not remove the test's output directory \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// A build that times out is still running in this process — typically an
    /// installer that fell back to interactive mode and is waiting for a
    /// person. Left alone it carries on into the next game's test, with its
    /// windows over that game's and its Wine session competing for the
    /// machine. Kill its Wine session so the installer returns, then give the
    /// build a moment to fail and tear down (unmount, remove the temp wrapp).
    private func stopTimedOutBuild(recorder: RecordingEventSubscriber) async {
        guard let installerPath = recorder.resolvedInstaller?.exePath,
              let tempWrapp = Self.enclosingAppBundle(of: URL(fileURLWithPath: installerPath)) else {
            return
        }
        WineEnvironment(appPath: tempWrapp).stopWineserver()
        _ = await recorder.waitForCompletion(timeout: 60)
    }

    /// The outermost `.app` bundle containing `url`, if any.
    private static func enclosingAppBundle(of url: URL) -> URL? {
        var bundle = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            bundle.appendPathComponent(component)
            if component.hasSuffix(".app") { return bundle }
        }
        return nil
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
        try await IntegrationSerial.shared.run { try await testGame(game) }
    }

    private func testGame(_ game: GameInfo) async throws {
        // Per-game progress for `sc test integration`'s live display. The
        // finished line's result agrees with this test's: any failed
        // expectation or thrown error makes it "failed".
        let outcome = GameOutcome(slug: game.id, progress: Self.progress)
        defer { outcome.finish() }

        // A Mac too busy for Wine to start would make this a test of the load,
        // not the game; see LoadGate.
        if LoadGate.ignoringLoad {
            if let load = LoadGate.heavyReadingNow() {
                Self.progress?.write(["event": "load", "message": "Testing \(game.id) on a heavily loaded Mac (--ignore-load): \(load.summary)."])
            }
        } else if let load = await LoadGate.overloadedReading() {
            let message = "Not testing \(game.id): the Mac is heavily loaded — \(load.summary). Wine would take minutes to start, or never start; quit the busy programs, or pass --ignore-load to test anyway."
            Self.progress?.write(["event": "load", "message": message])
            outcome.overloaded = true
            Issue.record(Comment(rawValue: message))
            return
        }

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
        // On every path out, including a build or check that throws: an output
        // directory left behind holds a whole wrapp.
        defer { if let dir = builtOutputDir { cleanup(dir) } }

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

            // Attach this build's log, every level, from LogStore: this
            // process's own log, without a trip through os_log (which the
            // test host may not be writing to — see MultiplexLogHandler).
            let logStart = LogStore.shared.nextSequence
            defer {
                LogStore.shared.flush()
                let lines = LogStore.shared.snapshot().entries
                    .filter { $0.seq >= logStart }
                    .map { LogFormatter.full(entry: $0) }
                if !lines.isEmpty {
                    Attachment.record(Data((lines.joined(separator: "\n") + "\n").utf8), named: "secondchance-install-\(game.id).txt")
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

            // Only a backstop for a build that hangs: the build times out
            // its own installer (30 minutes) and each patch, and reports
            // which one, so this must not cut a slow but healthy build short.
            let succeeded = await recorder.waitForCompletion(timeout: 3000)
            if !succeeded && recorder.failedError == nil {
                await stopTimedOutBuild(recorder: recorder)
            }

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

            // A failed patch doesn't fail the build, so it has to fail the test.
            for patch in recorder.failedPatches {
                outcome.expect(false, "Patch \(patch.id) failed: \(patch.message)")
            }
            let expectedPatches = GamePatchCatalog.shared.automaticPatches(forGame: game.id, source: .disk).map(\.id)
            outcome.expect(recorder.appliedPatches == expectedPatches,
                    "Applied patches \(recorder.appliedPatches) but expected \(expectedPatches)")

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
    /// Which suite: `disk` or `steam`, so `sc` keeps one row per game per source.
    let source: String
    let progress: ProgressFileWriter?
    let started = Date()
    /// Set once the test has run to its end without throwing.
    var completed = false
    var puppeteerExit: Int32?
    /// Held back because the Mac was too busy to test the game fairly.
    var overloaded = false
    /// Not tested, for a reason that isn't a failure (e.g. the Steam account
    /// doesn't own the game).
    var skipped: String?
    private var failedExpectations = 0

    init(slug: String, source: String = "disk", progress: ProgressFileWriter?) {
        self.slug = slug
        self.source = source
        self.progress = progress
        progress?.write(["event": "game", "source": source, "slug": slug, "phase": "started"])
    }

    func expect(_ condition: Bool, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, comment, sourceLocation: sourceLocation)
        if !condition { failedExpectations += 1 }
    }

    func phase(_ phase: String) {
        progress?.write(["event": "game", "source": source, "slug": slug, "phase": phase])
    }

    func finish() {
        let result: String
        if overloaded {
            result = "overloaded"
        } else if skipped != nil {
            result = "skipped"
        } else {
            result = completed && failedExpectations == 0 ? "passed" : "failed"
        }
        var record: [String: Any] = [
            "event": "game", "source": source, "slug": slug, "phase": "finished", "result": result,
            "seconds": Date().timeIntervalSince(started),
        ]
        if let puppeteerExit { record["puppeteerExit"] = Int(puppeteerExit) }
        if let skipped { record["message"] = skipped }
        progress?.write(record)
    }
}
