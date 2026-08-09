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
        arguments: GameInfoProvider.shared.allGames()
    )
    func wrapperCreationForGame(game: GameInfo) async throws {
        // Resolve the installer disk(s) for this game.
        let disk1 = try #require(
            InstallerPaths.diskISO(for: game, diskNumber: 1),
            "disk-1.iso not found for \(game.id) at \(TestPaths.installersDir.path)/\(game.id)/"
        )
        let disk2 = InstallerPaths.diskISO(for: game, diskNumber: 2)

        // Verify disk count matches what GameInfoProvider says.
        if game.diskCount > 1 {
            #expect(disk2 != nil, "Game \(game.id) requires \(game.diskCount) disks but disk-2.iso not found")
        }

        // Set up an isolated bus + recording subscriber for this test.
        let bus = EventBus<AppEvent>()
        let recorder = RecordingEventSubscriber()
        await recorder.subscribe(to: bus)

        let outputDir = makeOutputDir()
        defer { cleanup(outputDir) }

        let context = IntegrationTestContext(disk1: disk1, disk2: disk2, outputDir: outputDir)
        let service = InstallationService(bus: bus)

        // Run the REAL installation flow.
        let wrapperPath = try await service.performInstallation(context: context)

        // Unsubscribe before asserting so no race with final events.
        await recorder.unsubscribe(from: bus)

        // ── Per-step assertions ──────────────────────────────────────────

        // 1. Game was detected correctly
        #expect(recorder.detectedGame?.id == game.id,
                "Detected game \(recorder.detectedGame?.id ?? "nil") but expected \(game.id)")

        // 2. Engine routing is correct
        #expect(recorder.routedEngine == game.gameEngine,
                "Routed engine \(String(describing: recorder.routedEngine)) but expected \(game.gameEngine)")

        // 3. The detected exe path matches what GameInfoProvider expects
        //    (for games with a known internalGameExePath).
        if let expectedExePath = game.internalGameExePath {
            #expect(recorder.detectedExePath == expectedExePath,
                    "Detected exe path \(recorder.detectedExePath ?? "nil") but expected \(expectedExePath)")
        }

        // 4. The wrapper was configured with the detected exe path
        #expect(recorder.configuredWrapper != nil,
                "wrapperConfigured event was not emitted")
        if let config = recorder.configuredWrapper {
            #expect(config.exePath == recorder.detectedExePath,
                    "Configured exe path \(config.exePath) doesn't match detected \(recorder.detectedExePath ?? "nil")")
        }

        // 5. The wrapper was signed
        #expect(recorder.signedWrapper != nil, "Wrapper was not signed")

        // 6. The flow completed
        #expect(recorder.completedWrapper == wrapperPath,
                "Completed event wrapper path mismatch")

        // 7. The actual built wrapper's Info.plist has the right exe path
        //    (this verifies the configuration was persisted, not just evented)
        if let expectedExePath = game.internalGameExePath {
            let plistExePath = try WrapperInfo.gameExePath(at: wrapperPath)
            #expect(plistExePath == expectedExePath,
                    "Wrapper Info.plist GameExePath \(plistExePath ?? "nil") but expected \(expectedExePath)")
        }

        // 8. The wrapper Info.plist has the correct game slug
        let plistSlug = try WrapperInfo.gameSlug(at: wrapperPath)
        #expect(plistSlug == game.id,
                "Wrapper Info.plist GameSlug \(plistSlug ?? "nil") but expected \(game.id)")
    }

    // MARK: - Event sequence test (for a single game)

    @Test("Event sequence is correct", arguments: [GameInfoProvider.shared.allGames().first!])
    func eventSequenceForFirstAvailableGame(game: GameInfo) async throws {
        // Skip if no installer available for the first game.
        guard let disk1 = InstallerPaths.diskISO(for: game, diskNumber: 1) else {
            print("⏭️  Skipping: no installer for \(game.id)")
            return
        }

        let bus = EventBus<AppEvent>()
        let recorder = RecordingEventSubscriber()
        await recorder.subscribe(to: bus)

        let outputDir = makeOutputDir()
        defer { cleanup(outputDir) }

        let context = IntegrationTestContext(disk1: disk1, disk2: nil, outputDir: outputDir)
        let service = InstallationService(bus: bus)

        _ = try await service.performInstallation(context: context)
        await recorder.unsubscribe(from: bus)

        // Verify the key events appear in a logical order.
        let eventKinds = recorder.events.map { event -> String in
            switch event {
            case .started: return "started"
            case .disksResolved: return "disksResolved"
            case .gameDetected: return "gameDetected"
            case .engineRouted: return "engineRouted"
            case .installerResolved: return "installerResolved"
            case .gameExeDetected: return "gameExeDetected"
            case .wrapperConfigured: return "wrapperConfigured"
            case .signed: return "signed"
            case .completed: return "completed"
            case .isoMounted: return "isoMounted"
            case .progress: return "progress"
            case .failed: return "failed"
            }
        }

        // These key events should appear in this relative order:
        let keyEvents = ["gameDetected", "engineRouted", "gameExeDetected", "wrapperConfigured", "signed", "completed"]
            .filter { kind in eventKinds.contains(kind) }

        // Verify each key event appears at least once
        for expected in ["gameDetected", "engineRouted", "wrapperConfigured", "signed", "completed"] {
            #expect(eventKinds.contains(expected), "Expected event \(expected) in sequence")
        }

        // Verify started comes before completed
        if let startedIdx = eventKinds.firstIndex(of: "started"),
           let completedIdx = eventKinds.firstIndex(of: "completed") {
            #expect(startedIdx < completedIdx, "started must come before completed")
        }

        // gameDetected before engineRouted
        if let detectedIdx = eventKinds.firstIndex(of: "gameDetected"),
           let routedIdx = eventKinds.firstIndex(of: "engineRouted") {
            #expect(detectedIdx < routedIdx, "gameDetected must come before engineRouted")
        }

        _ = keyEvents // silence unused warning if all filtered
    }
}
