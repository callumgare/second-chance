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
    .serialized,
    .enabled(if: !HerDownloadCase.all.isEmpty, "No her-download*.exe or .dmg in installers/<slug>/")
)
struct HerDownloadInstallIntegrationTests {
    static let progress = ProgressFileWriter.fromEnvironment("PROGRESS_PATH")

    @Test("Each Her download builds and launches", .timeLimit(.minutes(60)), arguments: HerDownloadCase.all)
    func download(_ download: HerDownloadCase) async throws {
        try await IntegrationSerial.shared.run { try await buildAndLaunch(download) }
    }

    private func buildAndLaunch(_ download: HerDownloadCase) async throws {
        let game = download.game
        let outcome = GameOutcome(slug: download.label, source: "her-download", progress: Self.progress)
        defer { outcome.finish() }

        if !LoadGate.ignoringLoad, let load = await LoadGate.overloadedReading() {
            let message = "Not testing \(download.label): the Mac is heavily loaded — \(load.summary)."
            Self.progress?.write(["event": "load", "message": message])
            outcome.overloaded = true
            Issue.record(Comment(rawValue: message))
            return
        }
        if let reason = VMTarget.screenBlockedReason() {
            let message = "Not testing \(download.label): \(reason), so the game couldn't come to the front."
            Self.progress?.write(["event": "screen", "message": message])
            outcome.locked = true
            Issue.record(Comment(rawValue: message))
            return
        }

        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-her-integration-\(UUID().uuidString)")
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
                Attachment.record(Data((lines.joined(separator: "\n") + "\n").utf8), named: "secondchance-her-\(download.label).txt")
            }
        }

        let viewModel = await MainActor.run {
            WrappBuildViewModel(makeInput: { WrappBuildInput(herDownload: download.file, outputDir: outputDir, viewModel: $0) })
        }
        Task { await MainActor.run { Task { await viewModel.buildFromHerDownload() } } }
        // A backstop only: the build times out its own installer and patches.
        let succeeded = await recorder.waitForCompletion(timeout: 3000)
        Attachment.record(Data(recorder.events.map { "\($0)" }.joined(separator: "\n").utf8), named: "her-events-\(download.label).txt")

        outcome.expect(succeeded, "The build did not complete")
        try #require(recorder.failedError == nil, "The build failed: \(String(describing: recorder.failedError))")

        outcome.expect(recorder.detectedGame?.id == game.id, "Detected \(recorder.detectedGame?.id ?? "nil"), not \(game.id)")
        outcome.expect(recorder.routedEngine == game.gameEngine,
                       "Engine \(String(describing: recorder.routedEngine)), expected \(game.gameEngine)")
        // A Mac download's game lands where the disc's installer puts it;
        // the Windows download's installer has its own idea of where.
        if download.isMacDownload, let expectedExe = game.internalGameExePath {
            outcome.expect(recorder.detectedExePath == expectedExe, "Exe \(recorder.detectedExePath ?? "nil"), expected \(expectedExe)")
        }

        for patch in recorder.failedPatches {
            outcome.expect(false, "Patch \(patch.id) failed: \(patch.message)")
        }
        let expectedPatches = download.isMacDownload
            ? []
            : GamePatchCatalog.shared.automaticPatches(forGame: game.id, source: .herDownload).map(\.id)
        outcome.expect(recorder.appliedPatches == expectedPatches,
                       "Applied patches \(recorder.appliedPatches) but expected \(expectedPatches)")

        outcome.expect(recorder.configuredWrapp != nil, "wrappConfigured event not emitted")
        outcome.expect(recorder.signedWrapp != nil, "signed event not emitted")
        let wrapp = try #require(recorder.completedWrapp, "completed event not emitted")
        outcome.expect(try WrappInfo.gameSlug(at: wrapp) == game.id, "Wrapp GameSlug isn't \(game.id)")
        if let exe = WrappInfo.gameExe(at: wrapp) {
            outcome.expect(FileManager.default.fileExists(atPath: exe.path), "The wrapp's game exe isn't in it: \(exe.path)")
        }

        // Neither the unpacked installer nor the rest of the Cider app ships.
        let sharedSupport = wrapp.appendingPathComponent("Contents/SharedSupport")
        for leftover in ["prefix/drive_c/nancy-drew-installer", "cider-staging"] {
            outcome.expect(!FileManager.default.fileExists(atPath: sharedSupport.appendingPathComponent(leftover).path),
                           "\(leftover) shipped in the wrapp")
        }

        guard WrappInfo.wrappPuppeteerBundle() != nil else {
            Attachment.record("WrappPuppeteer not built — skipped the launch", named: "launch-skipped-\(download.label).txt")
            outcome.completed = true
            return
        }
        // A VM can't render Direct3D; the build above was still tested.
        if let reason = VMTarget.launchSkipReason(wrappURL: wrapp) {
            outcome.skipped = "\(game.title) \(reason)"
            outcome.completed = true
            return
        }
        outcome.phase("launching")
        let exitCode = try await AppPuppetRunner.run(wrappURL: wrapp, game: game)
        outcome.puppeteerExit = exitCode
        outcome.expect(exitCode == 0, "WrappPuppeteer exited \(exitCode)")
        outcome.completed = true
    }
}
