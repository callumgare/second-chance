//
//  HerDownloadInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Each Her Interactive download in installers/ built and launched for
//  real: the Her counterpart of DiskInstallIntegrationTests. A game is
//  tested once per download it has, as installers/<slug>/her-download*.exe
//  (the Windows installer) or her-download*.dmg (the Mac download); the
//  files are gitignored, so the suite disables itself when there are none.
//
//  Run with `sc test integration --source her-download [<slug>…]`.

import Foundation
import Testing
@testable import SecondChance
import GameCatalog
import SecondChanceKit

/// One download of one game.
struct HerDownloadCase: Sendable, CustomTestStringConvertible {
    let game: GameInfo
    let file: URL

    var isMacDownload: Bool { file.pathExtension.lowercased() == "dmg" }
    /// The row `sc` shows: the slug, and "mac" for the Mac download.
    var label: String { isMacDownload ? "\(game.id) mac" : game.id }
    var testDescription: String { "\(label) (\(file.lastPathComponent))" }

    /// Every download of the selected games.
    static let all: [HerDownloadCase] = TestGameFilter.selectedGames.flatMap { game in
        InstallerPaths.herDownloads(for: game).map { HerDownloadCase(game: game, file: $0) }
    }
}

@Suite(
    "Her download install — per game",
    .enabled(if: !HerDownloadCase.all.isEmpty, "No her-download*.exe or .dmg in installers/<slug>/")
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

            let expectedPatches = download.isMacDownload ? [] : GamePatchCatalogTests.editionPatches[game.id]?["her-download"] ?? []
            outcome.expect(recorder.appliedPatches == expectedPatches,
                           "Applied patches \(recorder.appliedPatches) but expected \(expectedPatches)")

            outcome.expect(recorder.configuredWrapp != nil, "wrappConfigured event not emitted")
            if let exe = WrappInfo.gameExe(at: wrapp) {
                outcome.expect(FileManager.default.fileExists(atPath: exe.path), "The wrapp's game exe isn't in it: \(exe.path)")
            }

            // Neither the unpacked installer nor the rest of the Cider app ships.
            let sharedSupport = wrapp.appendingPathComponent("Contents/SharedSupport")
            for leftover in ["prefix/drive_c/nancy-drew-installer", "cider-staging"] {
                outcome.expect(!FileManager.default.fileExists(atPath: sharedSupport.appendingPathComponent(leftover).path),
                               "\(leftover) shipped in the wrapp")
            }
        }
    }
}
