//
//  HerDownloadWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from a Her Interactive
//  Windows installer (.exe download).
//
//  Same shape as DiskWrappBuilder minus the disk-specific layout: resolve
//  installer → detect ONCE → base wrapp → run installer → configure →
//  finalize, through the same shared helpers as the disk flow, so it signs
//  and publishes the same events.
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
        await bus.publishWrappBuild(.started(source: .herDownload))

        // ── Resolve installer ──────────────────────────────────────────
        let installerPath = try await input.getHerInstallerPath()

        // ── Detect ONCE ────────────────────────────────────────────────
        await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
        let gameSlug = try await gameDetector.detectGame(fromInstaller: installerPath)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        logger.notice("Detected game: \(gameInfo.title)")
        await bus.publishWrappBuild(.gameDetected(gameInfo))
        await input.onGameDetected(gameInfo)

        // ── Build ──────────────────────────────────────────────────────
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            try await helper.createBaseWrapp(at: wrappPath)

            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            let (gameExePath, installerDir) = try await installerRunner.installGameWithWine(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                installerPath: installerPath
            )

            try helper.cleanupUnusedEngine(at: wrappPath, gameEngine: gameInfo.gameEngine)

            try helper.configureWrapp(
                at: wrappPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                installerDir: installerDir
            )
            await bus.publishWrappBuild(.wrappConfigured(
                exePath: gameExePath,
                installerDir: installerDir,
                gameInfo: gameInfo
            ))

            let finalPath = try await helper.finalize(wrapp: wrappPath, gameInfo: gameInfo, input: input)
            helper.unregisterTemporaryWrapp(wrappPath)

            let (shouldLaunch, args) = await input.shouldLaunchGame()
            if shouldLaunch {
                try await helper.launchGame(at: finalPath, with: args)
            }

            return finalPath
        } catch {
            helper.removeTempWrapp(wrappPath)

            let installError = (error as? WrappBuildError) ?? .internalError(error.localizedDescription)
            await bus.publishWrappBuild(.failed(installError))
            throw error
        }
    }
}
