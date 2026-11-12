//
//  HerDownloadInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Each Her Interactive download in the installers store built and launched
//  for real: the Her counterpart of DiskInstallIntegrationTests. A game is
//  tested once per Her edition whose download is in the store,
//  `<bundle id>/her-windows/installer.exe` (the Windows installer) or
//  `<bundle id>/her-mac/installer.dmg` (the Mac download); the suite
//  disables itself when there are none.
//
//  Run with `sc test integration --source her-download [<slug>…]`.

import Foundation
import Testing
@testable import SecondChance
import GameCatalog
import SecondChanceKit
import WrappBuilder

/// One download of one game.
struct HerDownloadCase: Sendable, CustomTestStringConvertible {
    let game: GameInfo
    let file: URL
    let edition: String
    let isMacDownload: Bool
    /// The row `sc` shows: the slug, and "mac" for the Mac download.
    var label: String { isMacDownload ? "\(game.id) mac" : game.id }
    var testDescription: String { "\(label) (\(edition))" }

    /// Every download of the selected games.
    static let all: [HerDownloadCase] = TestGameFilter.selectedGames.flatMap { game in
        InstallerPaths.herDownloads(for: game).compactMap { found in
            found.files.first.map { HerDownloadCase(game: game, file: $0, edition: found.edition, isMacDownload: found.format == "mac") }
        }
    }
}

@Suite(
    "Her download install — per game",
    .enabled(if: !HerDownloadCase.all.isEmpty, "No Her downloads in the installers store")
)
struct HerDownloadInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    @Test("Each Her download builds and launches", arguments: HerDownloadCase.all)
    func download(_ download: HerDownloadCase) async throws {
        try await buildAndLaunch(download)
    }

    private func buildAndLaunch(_ download: HerDownloadCase) async throws {
        let game = download.game
        let run = IntegrationGameRun(game: game, label: download.label, source: "her-download", progress: Self.progress)
        try await run.run { _ in
            IntegrationGameRun.Build(
                expectedEngine: game.gameEngine,
                installers: [download.file],
                makeInput: { outputDir, viewModel in
                    WrappBuildInput(herDownload: download.file, outputDir: outputDir, viewModel: viewModel)
                },
                start: { await $0.build(from: .herDownload) }
            )
        } check: { recorder, wrapp, outcome in
            // A Mac download's game lands where the disc's installer puts it;
            // the Windows download's installer has its own idea of where.
            if download.isMacDownload, let expectedExe = game.internalGameExePath {
                outcome.expect(recorder.detectedExePath == expectedExe, "Exe \(recorder.detectedExePath ?? "nil"), expected \(expectedExe)")
            }

            // A fixture that couldn't be read would expect no patches, and pass a
            // build that applied none it should have.
            outcome.expect(!GamePatchCatalogTests.editionPatches.isEmpty, "TestFixtures/edition-patches.json couldn't be read from \(TestPaths.repoRoot.path)")
            // A Mac download that is the game's disc builds as the disc does
            // (docs/her-download.md#mac-downloads-that-are-the-games-disc):
            // its discs resolved, the disc's patches, the disc kept.
            let builtAsDisc = download.isMacDownload && recorder.disksResolved != nil
            let expectedPatches = builtAsDisc ? GamePatchCatalogTests.editionPatches[game.id]?["disc"] ?? []
                : download.isMacDownload ? [] : GamePatchCatalogTests.editionPatches[game.id]?["her-download"] ?? []
            outcome.expect(recorder.appliedPatches == expectedPatches,
                           "Applied patches \(recorder.appliedPatches) but expected \(expectedPatches)")

            outcome.expect(recorder.configuredWrapp != nil, "wrappConfigured event not emitted")
            if let exe = WrappInfo.gameExe(at: wrapp) {
                outcome.expect(FileManager.default.fileExists(atPath: exe.path), "The wrapp's game exe isn't in it: \(exe.path)")
            }

            // Neither the unpacked installer nor the rest of the Cider app
            // ships; a disc does, for a game that checks for it.
            let sharedSupport = wrapp.appendingPathComponent("Contents/SharedSupport")
            for leftover in (builtAsDisc ? [] : ["prefix/drive_c/nancy-drew-installer"]) + ["cider-staging"] {
                outcome.expect(!FileManager.default.fileExists(atPath: sharedSupport.appendingPathComponent(leftover).path),
                               "\(leftover) shipped in the wrapp")
            }
        }
    }
}
