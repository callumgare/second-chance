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
//    - Games build side by side, as many as `IntegrationStages.build` lets
//      in, and launch one at a time.
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
import GameCatalog
import SecondChanceKit

@Suite(
    "Disk install — per game",
    .disabled(if: !InstallersPresent.shouldRun(), "No installer ISOs found in installers/")
)
struct DiskInstallIntegrationTests {

    /// Where `sc test integration` follows progress (`TEST_RUNNER_PROGRESS_PATH`).
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

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
        try await testGame(game)
    }

    private func testGame(_ game: GameInfo) async throws {
        // SKIP_BUILD=1 (`sc test integration --refresh-wrapp template|skip`):
        // skip the install and use a pre-existing wrapp from the wrapps dir if
        // present. Useful for iterating on the WrappPuppeteer test without
        // waiting for a full Wine install.
        let skipBuild = ProcessInfo.processInfo.environment["SKIP_BUILD"] == "1"
        let prebuiltWrapp = TestPaths.wrappsDir.appendingPathComponent("Nancy Drew - \(game.title).app")
        let usingPrebuiltWrapp = skipBuild && FileManager.default.fileExists(atPath: prebuiltWrapp.path)

        let run = IntegrationGameRun(game: game, label: game.id, source: "disk", progress: Self.progress)
        try await run.run(prebuiltWrapp: usingPrebuiltWrapp ? prebuiltWrapp : nil) { outcome in
            let disk1 = try #require(
                InstallerPaths.diskISO(for: game, diskNumber: 1),
                "disk-1.iso not found for \(game.id) at \(TestPaths.installersDir.path)/\(game.id)/"
            )
            let disk2 = InstallerPaths.diskISO(for: game, diskNumber: 2)
            if game.diskCount > 1 {
                outcome.expect(disk2 != nil, "Game \(game.id) requires \(game.diskCount) disks but disk-2.iso not found")
            }
            return IntegrationGameRun.Build(
                expectedEngine: game.gameEngine,
                installers: [disk1] + (disk2.map { [$0] } ?? []),
                makeInput: { outputDir, viewModel in
                    WrappBuildInput(disk1: disk1, disk2: disk2, outputDir: outputDir, viewModel: viewModel)
                },
                start: { await $0.buildFromDisk() }
            )
        } check: { recorder, wrapp, outcome in
            if let expectedExe = game.internalGameExePath {
                outcome.expect(recorder.detectedExePath == expectedExe,
                        "Detected exe path \(recorder.detectedExePath ?? "nil") but expected \(expectedExe)")
                let plistExe = try WrappInfo.gameExePath(at: wrapp)
                outcome.expect(plistExe == expectedExe, "Wrapp plist GameExePath \(plistExe ?? "nil") ≠ \(expectedExe)")
            }

            let expectedPatches = await GamePatchCatalog.shared.automaticPatches(forGame: game.id, source: .disk).map(\.id)
            outcome.expect(recorder.appliedPatches == expectedPatches,
                    "Applied patches \(recorder.appliedPatches) but expected \(expectedPatches)")
            outcome.expect(recorder.configuredWrapp != nil, "wrappConfigured event not emitted")

            // Event ordering.
            let kinds = recorder.events.map { "\($0)" }
            if let a = kinds.firstIndex(where: { $0.hasPrefix("gameDetected") }),
               let b = kinds.firstIndex(where: { $0.hasPrefix("engineRouted") }) {
                outcome.expect(a < b, "gameDetected must precede engineRouted")
            }
        }
    }
}
