//
//  DownloadWrappBuilder.swift
//  SecondChance
//
//  Builds a wrapp of a program its makers give away, downloaded from where
//  its bundle says: the download source, hidden on the welcome screen
//  until asked for.
//
//  Resource ownership: this builder creates the temp wrapp and the folder
//  the download is unpacked into, and removes both on the success AND
//  error paths. The download itself stays in the cache, once per Mac.
//

import Foundation
import Logging
import GameCatalog
import SecondChanceKit
import SecondChanceReporting
import WrappBuilder

/// Builds a download edition (docs/wrapp-build.md#the-download-source): the
/// person picks a program and is told why it's free, its input is fetched
/// (`Downloader`: the first URL with the bundle's hash, cached by it) and
/// unpacked, and its Wrappfile's stage copies it into the wrapp.
final class DownloadWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let wineManager: WineManager
    private let downloader: Downloader
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.DownloadWrappBuilder")

    /// A download bigger than this gets a progress step saying it may take a
    /// while: an archive's copy comes at about 0.4 MB/s.
    nonisolated static let bigDownload: Int64 = 50_000_000

    init(
        helper: WrappBuildHelper = .shared,
        wineManager: WineManager = .shared,
        downloader: Downloader = DownloadWrappBuilder.standardDownloader(),
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.wineManager = wineManager
        self.downloader = downloader
        self.bus = bus
    }

    /// The downloader every build shares: the standard cache, and a
    /// User-Agent naming Second Chance and where to find it.
    nonisolated static func standardDownloader() -> Downloader {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return Downloader(cache: Downloader.standardCache(),
                          userAgent: "SecondChance/\(version) (+https://github.com/callumgare/second-chance)")
    }

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .download))
        await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
        let editions = try await Blocking.run { try ShippedBundles.downloadEditions() }
        let chosen = try await input.chooseDownload(from: editions)
        let game = chosen.game
        logger.notice("Downloading \(game.programID) (\(chosen.edition))")
        await bus.publishWrappBuild(.gameDetected(game))
        try await input.onGameDetected(game)
        let notice = DownloadNotice(licence: chosen.licence, game: game.title)
        try await input.confirmDownload(notice)

        let wrappPath = helper.createTemporaryWrappPath()
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("SecondChance-download-\(UUID().uuidString)")
        logger.notice("Temporary wrapp: \(wrappPath.path)")
        do {
            // A game Wine doesn't run needs no Wine to build: its files are
            // only copied in.
            try await helper.createBaseWrapp(at: wrappPath, composition: game.composition,
                                             buildsWithWine: game.composition.has(.wine))
            let request = try DownloadRequest(chosen.input)
            let big = (request.size ?? 0) > Self.bigDownload
            await bus.publishWrappBuild(.progress(.copyingInstaller(substep: big
                ? String(localized: "Downloading the game. This is a big download and may take a while")
                : String(localized: "Downloading the game"))))
            let download = try await fetch(request, game: game)
            try await unpack(download.file, as: chosen.input, firstURL: request.urls.first, into: unpacked)

            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            await bus.publishWrappBuild(.engineRouted(composition: game.composition, gameInfo: game))
            let slug = game.id, edition = chosen.edition
            guard let plan = try await Blocking.run({ try ShippedBundles.plan(forGame: slug, edition: edition) }) else {
                throw WrappBuildError.buildRecipeProblem("\(game.programID)'s \(chosen.edition) edition names no stage")
            }
            try await run(plan, inputs: [chosen.input.id: unpacked], wrappPath: wrappPath)
            // What the wrapp starts: a Wine program's exe, or for ScummVM the
            // folder of the game's data, which it reads.
            let installDir = chosen.installDir.map { $0.hasPrefix("C:") ? String($0.dropFirst(2)) : $0 }
            let launcher = game.composition.launcher
            // DOSBox's program is on its own C:, the others' on Wine's.
            let layout = WrappLayout(app: wrappPath)
            let drive = launcher == .dosbox ? layout.dosboxC : layout.driveC
            guard let exe = launcher == .scummvm ? installDir : game.internalGameExePath,
                  FileManager.default.fileExists(atPath: WrappLayout.onDriveC(exe, in: drive).path) else {
                throw WrappBuildError.gameExecutableNotFound
            }
            await bus.publishWrappBuild(.gameExeDetected(path: exe, gameInfo: game))

            // Why it was free to have, for anyone who wants to know later,
            // with the licence's own words when it has some.
            var licence = notice.licenceFile(from: chosen.licenceFrom)
            if let file = chosen.licenceFile {
                do {
                    licence += "\n" + (try String(contentsOf: unpacked.appendingPathComponent(file), encoding: .utf8))
                } catch {
                    throw WrappBuildError.buildRecipeProblem("\(game.programID): its licence-file \(file) isn't in the download")
                }
            }
            try licence.write(to: WrappLayout(app: wrappPath).resources.appendingPathComponent("Licence.txt"), atomically: true, encoding: .utf8)
            try await helper.cleanupUnusedEngine(at: wrappPath, composition: game.composition)

            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: game, source: .download, gameExePath: exe,
                installerDir: launcher == .scummvm ? exe : "",
                configureINI: false, edition: chosen.edition, input: input
            )
            try? FileManager.default.removeItem(at: unpacked)
            await helper.launchIfAsked(finalPath, input: input)
            return finalPath
        } catch {
            await helper.removeTempWrapp(wrappPath)
            do {
                try FileManager.default.removeItem(at: unpacked)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                logger.warning("Couldn't remove \(unpacked.path): \(error.localizedDescription)")
            }
            await bus.publishWrappBuild(.failed(WrappBuildError(error)))
            throw error
        }
    }

    /// The input's file: from the cache, or the first URL that has it. Every
    /// URL that didn't is reported, so a dead one is noticed even when the
    /// next took over.
    private func fetch(_ request: DownloadRequest, game: GameInfo) async throws -> Download {
        do {
            let download = try await downloader.fetch(request)
            report(download.failures, game: game)
            return download
        } catch let error as DownloadError where error.kind == .unavailable {
            report(error.failures, game: game)
            logger.critical("❌ \(game.title) couldn't be downloaded: \(error.failures.map(\.description).joined(separator: "; "))")
            throw WrappBuildError.downloadUnavailable(title: game.title)
        }
    }

    private func report(_ failures: [Download.Failure], game: GameInfo) {
        for failure in failures {
            _ = FailureReporter.sendWithoutAsking(FailureReport(
                what: "Downloading a free game", kind: "url-failed",
                game: game.id, source: WrappSource.download.rawValue, engine: game.composition.engineTag,
                tags: ["host": failure.url.host ?? "unknown"]
            ))
        }
    }

    /// The download as the folder its input is: the file itself in one for
    /// `unpack: none`, a zip's contents for `zip`.
    private func unpack(_ file: URL, as input: Manifest.Input, firstURL: URL?, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch input.unpack ?? "none" {
        case "none":
            let name = firstURL?.lastPathComponent ?? input.id
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
        case "zip":
            let result = try await Process.output(of: "/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
            guard result.succeeded else {
                throw WrappBuildError.internalError("Couldn't unpack \(input.id): \(result.errorOutput)")
            }
        case let other:
            throw WrappBuildError.buildRecipeProblem("\(input.id): unpacking \(other) isn't supported yet")
        }
        logger.notice("Unpacked \(input.id) (\(input.unpack ?? "none"))")
    }

    /// The edition's plan: each `COPY --from=<input>` copies the unpacked
    /// input into the wrapp's C: drive. Anything else a download edition
    /// can't run yet, and fails before it copies anything wrongly.
    private func run(_ plan: BuildPlan, inputs: [String: URL], wrappPath: URL) async throws {
        let layout = WrappLayout(app: wrappPath)
        for step in plan.stages.flatMap(\.steps) {
            logger.debug("Plan step: \(step) (\(step.origin))")
            guard step.module == nil, step.instruction == "COPY", let from = PlannedStep.input(in: step.option("from")),
                  let source = inputs[from],
                  step.arguments.count == 2 else {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): the download flow can't run \(step)")
            }
            // In full form, through its type's place in the app (`wine:C:/…`
            // in the prefix, a bare `/…` in Contents/); Lure's bare `C:/…`
            // is allowed until it moves (LegacyPaths).
            let destination = step.arguments[1]
            let written = destination.hasPrefix("C:/") ? "wine:" + destination : destination
            guard let target = layout.location(written) else {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): \(destination) has no place in the app")
            }
            let subpath = step.arguments[0] == "." ? "" : step.arguments[0]
            try await Blocking.run {
                let files = FileManager.default
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                let root = subpath.isEmpty ? source : source.appendingPathComponent(subpath)
                for item in try files.contentsOfDirectory(atPath: root.path) {
                    try files.copyItem(at: root.appendingPathComponent(item), to: target.appendingPathComponent(item))
                }
            }
            logger.notice("Copied \(from) into \(destination)")
        }
    }
}
