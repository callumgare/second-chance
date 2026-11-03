//
//  DownloadInstallIntegrationTests.swift
//  SecondChanceTests
//
//  Each free game a shipped bundle has a download edition of, downloaded,
//  built and launched for real: the download counterpart of
//  DiskInstallIntegrationTests. It needs the internet, and fetches from
//  the places the bundles name (once per Mac: downloads are cached), so it
//  runs only when asked for.
//
//  Run with `sc test integration --source download [<slug>…]`.

import Foundation
import Testing
@testable import SecondChance
import GameCatalog
import SecondChanceKit

/// One game's download edition.
struct DownloadCase: Sendable, CustomTestStringConvertible {
    let game: GameInfo
    var testDescription: String { game.id }

    /// The selected games that have a download edition.
    static let all: [DownloadCase] = {
        let downloadable = Set(((try? ShippedBundles.downloadEditions()) ?? []).map(\.game.id))
        return TestGameFilter.selectedGames.filter { downloadable.contains($0.id) }.map(DownloadCase.init)
    }()
}

@Suite(
    "Download install — per game",
    // Only when sc asks for this source: it downloads from the internet.
    .enabled(if: !DownloadCase.all.isEmpty, "No shipped bundle has a download edition among the selected games")
)
struct DownloadInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    @Test("Each free game downloads, builds and launches", arguments: DownloadCase.all)
    func download(_ download: DownloadCase) async throws {
        let game = download.game
        let run = IntegrationGameRun(game: game, label: game.id, source: "download", progress: Self.progress)
        try await run.run { _ in
            IntegrationGameRun.Build(
                expectedEngine: game.gameEngine,
                installers: [],
                makeInput: { outputDir, viewModel in
                    WrappBuildInput(download: game.programID, outputDir: outputDir, viewModel: viewModel)
                },
                start: { await $0.build(from: .download) }
            )
        } check: { recorder, wrapp, outcome in
            if let expectedExe = game.internalGameExePath {
                outcome.expect(recorder.detectedExePath == expectedExe, "Exe \(recorder.detectedExePath ?? "nil"), expected \(expectedExe)")
            }
            outcome.expect(recorder.configuredWrapp != nil, "wrappConfigured event not emitted")
            if let exe = WrappInfo.gameExe(at: wrapp) {
                outcome.expect(FileManager.default.fileExists(atPath: exe.path), "The wrapp's game exe isn't in it: \(exe.path)")
            }
            let licence = wrapp.appendingPathComponent("Contents/Resources/Licence.txt")
            outcome.expect(FileManager.default.fileExists(atPath: licence.path), "The wrapp has no Licence.txt")
        }
    }
}
