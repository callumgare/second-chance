//
//  HerDownloadWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from a Her Interactive
//  Windows installer (.exe download).
//
//  Same shape as DiskWrappBuilder minus the disk-specific layout: resolve
//  installer → detect ONCE → base wrapp → run installer → configure →
//  finalize. Going through the shared helpers means it now signs and
//  publishes events like the disk flow (the legacy path skipped signing).
//

import Foundation
import Logging

/// Builds a wrapp from a Her Interactive downloaded installer.
final class HerDownloadWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameDetector: GameDetector
    private let gameInfoProvider: GameInfoProvider
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.HerDownloadWrappBuilder")

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameDetector: GameDetector = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameDetector = gameDetector
        self.gameInfoProvider = gameInfoProvider
        self.bus = bus
    }

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishInstallation(.started(source: .herDownload))

        // ── Resolve installer ──────────────────────────────────────────
        let installerPath = try await input.getHerInstallerPath()

        // ── Detect ONCE ────────────────────────────────────────────────
        await bus.publishInstallation(.progress(.detectingGame(substep: nil)))
        let gameSlug = try await gameDetector.detectGame(fromInstaller: installerPath)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        logger.notice("Detected game: \(gameInfo.title)")
        await bus.publishInstallation(.gameDetected(gameInfo))
        await input.onGameDetected(gameInfo)

        // ── Build ──────────────────────────────────────────────────────
        let wrapperPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapper: \(wrapperPath.path)")

        do {
            try await helper.createBaseWrapp(at: wrapperPath)

            await bus.publishInstallation(.progress(.installingGame(substep: nil)))
            let (gameExePath, installerDir) = try await installerRunner.installGameWithWine(
                wrapperPath: wrapperPath,
                gameInfo: gameInfo,
                installerPath: installerPath
            )

            try helper.cleanupUnusedEngine(at: wrapperPath, gameEngine: gameInfo.gameEngine)

            try helper.configureWrapp(
                at: wrapperPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                installerDir: installerDir
            )
            await bus.publishInstallation(.wrapperConfigured(
                exePath: gameExePath,
                installerDir: installerDir,
                gameInfo: gameInfo
            ))

            let finalPath = try await helper.finalize(wrapp: wrapperPath, gameInfo: gameInfo, input: input)
            helper.unregisterTemporaryWrapp(wrapperPath)

            let (shouldLaunch, args) = await input.shouldLaunchGame()
            if shouldLaunch {
                try await helper.launchGame(at: finalPath, with: args)
            }

            return finalPath
        } catch {
            helper.removeTempWrapp(wrapperPath)

            let installError = (error as? InstallationError) ?? .internalError(error.localizedDescription)
            await bus.publishInstallation(.failed(installError))
            throw error
        }
    }
}
