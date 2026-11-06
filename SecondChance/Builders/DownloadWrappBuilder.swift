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

        let folder = helper.createBuildFolder()
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("SecondChance-download-\(UUID().uuidString)")
        logger.notice("Working folder: \(folder.path)")
        await bus.publishWrappBuild(.wrappStarted(path: folder))
        do {
            let template = try await helper.template()
            await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))
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
            // Each stage in a tree of its own, from empty: a game Wine doesn't
            // run has no Wine, as nothing puts it there. The template comes last.
            let wrappPath = try await run(plan, inputs: [chosen.input.id: unpacked], folder: folder, game: game, input: input)
            try await Blocking.run { try WrappAssembler.layIn(template, into: wrappPath) }
            // What the wrapp starts, as the plan's launch says: it must be
            // there, where its module places it. The settings' older keys
            // name a program on a drive, which a ScummVM game's data in the
            // app isn't.
            let layout = WrappLayout(app: wrappPath)
            guard let launch = plan.launch else { throw WrappBuildError.gameExecutableNotFound }
            guard let program = layout.location(launch.program, places: helper.places),
                  FileManager.default.fileExists(atPath: program.path) else {
                throw WrappBuildError.gameExecutableNotFound
            }
            let exe = launch.legacyProgramPath(places: helper.places) ?? ""
            await bus.publishWrappBuild(.gameExeDetected(path: launch.shownPath(places: helper.places), gameInfo: game))

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

            let finalPath = try await helper.completeBuild(
                wrapp: wrappPath, gameInfo: game, source: .download, gameExePath: exe, installerDir: "",
                edition: chosen.edition, launch: launch, app: plan.app, input: input
            )
            try? FileManager.default.removeItem(at: unpacked)
            await helper.removeTempWrapp(folder)
            await helper.launchIfAsked(finalPath, input: input)
            return finalPath
        } catch {
            await helper.removeFailedBuild(folder)
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

    /// The edition's plan, carried out by the runner (docs/wrapp-build.md#the-runner),
    /// each stage in its own tree in `folder`: the input is the download,
    /// unpacked. The target's tree, which becomes the wrapp.
    private func run(_ plan: BuildPlan, inputs: [String: URL], folder: URL, game: GameInfo, input: WrappBuildInput) async throws -> URL {
        let (configuration, emitter) = AppRunner.configuration(bus: bus, input: input, game: game, inputs: GivenInputs(inputs),
                                                               downloader: downloader, helper: helper)
        let tree: URL
        do {
            tree = try await PlanRunner(plan: plan, configuration: configuration).build(in: folder)
        } catch let error as StepFailure {
            await emitter.finish()
            throw WrappBuildError.buildRecipeProblem(error.description)
        } catch {
            await emitter.finish()
            throw error
        }
        await emitter.finish()
        return tree
    }
}
