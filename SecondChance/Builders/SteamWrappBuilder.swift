//
//  SteamWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from a Steam library.
//
//  Genuinely different from the installer-based sources: no setup.exe is
//  run — the Steam client is installed into the wrapp, the user installs
//  the game through Steam's own UI, and the game is then located and
//  configured. Not yet implemented; kept as a real builder with the
//  correct structure so the source dispatch is uniform.
//

import Foundation
import Logging

/// Builds a wrapp from a Steam installation. Stub — see the design notes in
/// docs/installation-flow.md §5.
final class SteamWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.SteamWrappBuilder")

    init(
        helper: WrappBuildHelper = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.bus = bus
    }

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .steam))

        // TODO: Install the Steam client into a fresh wrapp, let the user
        // install the game via Steam's UI, then locate + configure it.
        // (The old GameInstaller.buildFromSteam stub created a base
        // wrapp and installed the Steam client before throwing; that
        // half-path is not worth carrying — it just leaked a temp wrapp.)
        logger.notice("Steam source not yet implemented")

        let installError = WrappBuildError.steamNotFullyImplemented
        await bus.publishWrappBuild(.failed(installError))
        throw installError
    }
}
