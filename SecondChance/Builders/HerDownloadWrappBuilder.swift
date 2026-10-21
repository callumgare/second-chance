//
//  HerDownloadWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from a game bought from
//  Her Interactive's store: a Windows installer (.exe) or a Mac download
//  (.dmg).
//
//  A Windows installer is unpacked into the layout a disc has and installed
//  as one is; a Mac download is a Cider (Wine) app with the installed
//  Windows game inside, which is lifted straight out. Both then go through
//  the same shared tail as the other sources, so they sign and publish the
//  same events. docs/her-download.md has the details of both formats.
//

import Foundation
import Logging

/// Builds a wrapp from a Her Interactive download.
final class HerDownloadWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameDetector: GameDetector
    private let gameInfoProvider: GameInfoProvider
    private let isoMounter: ISOMounter
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.HerDownloadWrappBuilder")
    private let fileManager = FileManager.default

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameDetector: GameDetector = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        isoMounter: ISOMounter = ISOMounter(),
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameDetector = gameDetector
        self.gameInfoProvider = gameInfoProvider
        self.isoMounter = isoMounter
        self.bus = bus
    }

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .herDownload))

        let download = try await input.getHerInstallerPath()
        logger.notice("Her Interactive download: \(download.path)")
        if download.pathExtension.lowercased() == "dmg" {
            return try await build(fromMacDownload: download, input: input)
        }
        return try await build(fromWindowsInstaller: download, input: input)
    }

    // MARK: - Windows installer

    private func build(fromWindowsInstaller installer: URL, input: WrappBuildInput) async throws -> URL {
        // ── Detect ONCE ────────────────────────────────────────────────
        let gameInfo: GameInfo
        do {
            await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
            let gameSlug = try await gameDetector.detectGame(fromHerInstaller: installer)
            gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
            logger.notice("Detected game: \(gameInfo.title)")
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
        } catch {
            await publishFailure(error)
            throw error
        }

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            try await helper.createBaseWrapp(at: wrappPath)
            let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
            let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")

            // An InstallShield launcher unpacks into the layout a disc has,
            // and then installs silently from an answer file as a disc does.
            // Anything else runs as it is, and asks its questions itself.
            await bus.publishWrappBuild(.progress(.copyingInstaller(substep: "Unpacking the installer")))
            let unpacked = try await installerRunner.unpackInstallShieldLauncher(installer, at: wrappPath)
            if unpacked {
                helper.installAnswerFile(forGame: gameInfo.id, source: .herDownload, into: installerBaseDir)
            }

            // ── Install ──────────────────────────────────────────────────
            // Both engines install under Wine: a ScummVM game's data is in
            // the installer's cabinets too, and ScummVM plays it from where
            // the installer put it. Wine is stripped from a ScummVM wrapp
            // only once the installer and the patches have run.
            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            try await publishEngineRoute(for: gameInfo)
            let (gameExePath, _) = try await installerRunner.installGameWithWine(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                source: .herDownload,
                installerPath: unpacked ? nil : installer
            )

            // Unlike a disc, nothing reads the installer once the game is in.
            if unpacked && !DebugSettings.shared.skipInstaller {
                removeQuietly(installerBaseDir, what: "the unpacked installer")
            }

            if !DebugSettings.shared.skipInstaller {
                try helper.cleanupUnusedEngine(at: wrappPath, gameEngine: gameInfo.gameEngine)
            }

            return try await finish(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                input: input
            )
        } catch {
            helper.removeTempWrapp(wrappPath)
            await publishFailure(error)
            throw error
        }
    }

    // MARK: - Mac download

    private func build(fromMacDownload image: URL, input: WrappBuildInput) async throws -> URL {
        // ── Mount, recognise and detect ONCE ───────────────────────────
        let package: CiderPackage
        let gameInfo: GameInfo
        do {
            // Second Chance isn't sandboxed, so the volume needs no grant.
            let volume = try await isoMounter.mount(image)
            await bus.publishWrappBuild(.isoMounted(volume))

            await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
            do {
                package = try CiderPackage(volume: volume)
            } catch let notCider as CiderPackage.NotCider {
                logger.critical("\(image.lastPathComponent) isn't a Cider installer: \(notCider)")
                throw WrappBuildError.unsupportedMacDownload(
                    reason: "it isn't one of the Mac downloads made with Cider (\(notCider))")
            }
            let gameSlug = gameDetector.detectGame(fromCiderPackage: package)
            gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
            logger.notice("Detected game: \(gameInfo.title)")
            await bus.publishWrappBuild(.gameDetected(gameInfo))
            try await input.onGameDetected(gameInfo)
        } catch {
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            try await helper.createBaseWrapp(at: wrappPath)
            let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")

            await bus.publishWrappBuild(.progress(.installingGame(substep: "Unpacking the game")))
            try await publishEngineRoute(for: gameInfo)

            // Staged inside the wrapp, so moving the game out of it into
            // drive_c is a rename rather than a copy.
            let staging = wrappPath.appendingPathComponent("Contents/SharedSupport/cider-staging")
            let bus = self.bus
            let gameExe = try await package.extractGame(into: driveCPath, staging: staging) { percent in
                await bus.publishWrappBuild(.progress(.installingGame(substep: "Unpacking the game (\(percent)%)")))
            }
            removeQuietly(staging, what: "the rest of the Cider app")
            await isoMounter.unmountAll()

            let gameExePath = "/" + gameExe.path(relativeTo: driveCPath)
            await bus.publishWrappBuild(.gameExeDetected(path: gameExePath, gameInfo: gameInfo))

            // Her Interactive's patches are Windows updaters that look for
            // the game their own installer registered; a Cider build never
            // ran one, and it is a later build than they patch anyway.
            logger.notice("Not applying game patches: a Mac download is a later build than Her Interactive's patches update")

            try helper.cleanupUnusedEngine(at: wrappPath, gameEngine: gameInfo.gameEngine)

            return try await finish(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                input: input
            )
        } catch {
            helper.removeTempWrapp(wrappPath)
            await isoMounter.unmountAll()
            await publishFailure(error)
            throw error
        }
    }

    // MARK: - Shared steps

    /// Publish which engine the game runs under; a Her download is only ever
    /// a Wine or a ScummVM game.
    private func publishEngineRoute(for gameInfo: GameInfo) async throws {
        switch gameInfo.gameEngine {
        case .wine, .scummvm:
            await bus.publishWrappBuild(.engineRouted(engine: gameInfo.gameEngine, gameInfo: gameInfo))
        default:
            throw WrappBuildError.unsupportedEngine
        }
    }

    /// Configure → sign → save → launch. ScummVM plays the game from its
    /// installed folder, which is the folder the exe is in for both formats.
    private func finish(
        wrappPath: URL,
        gameInfo: GameInfo,
        gameExePath: String,
        input: WrappBuildInput
    ) async throws -> URL {
        let gameDir = (gameExePath as NSString).deletingLastPathComponent
        try helper.configureWrapp(
            at: wrappPath,
            gameInfo: gameInfo,
            gameExePath: gameExePath,
            installerDir: gameDir
        )
        await bus.publishWrappBuild(.wrappConfigured(
            exePath: gameExePath,
            installerDir: gameDir,
            gameInfo: gameInfo
        ))

        let finalPath = try await helper.finalize(wrapp: wrappPath, gameInfo: gameInfo, input: input)
        helper.unregisterTemporaryWrapp(wrappPath)

        let (shouldLaunch, args) = await input.shouldLaunchGame()
        if shouldLaunch {
            try await helper.launchGame(at: finalPath, with: args)
        }
        return finalPath
    }

    private func publishFailure(_ error: Error) async {
        let buildError = (error as? WrappBuildError) ?? .internalError(error.localizedDescription)
        await bus.publishWrappBuild(.failed(buildError))
    }

    private func removeQuietly(_ url: URL, what: String) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.warning("Couldn't remove \(what) at \(url.path): \(error)")
        }
    }
}
