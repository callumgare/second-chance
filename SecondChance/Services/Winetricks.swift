//
//  Winetricks.swift
//  SecondChance
//
//  Installing winetricks verbs into a prefix. Winetricks is bundled in
//  Second Chance.app, not in wrapps, so only a build runs it.

import Foundation
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Winetricks")

struct Winetricks {
    let wine: Wine
    let script: URL?

    init(wine: Wine, script: URL? = Bundle.main.url(forResource: "winetricks", withExtension: nil)) {
        self.wine = wine
        self.script = script
    }

    /// Install `verb`, as the wine module's prefix set-up names it
    /// (Modules/wine/prefix.yaml). Logged and stopped like any other Wine
    /// program (`Wine.run`); winetricks failing throws `winetricksFailed`.
    func install(_ verb: String) async throws {
        guard let script else { throw WineError.winetricksNotFound }
        do {
            // cnc_ddraw downloads its release the first time, so allow for a
            // slow connection.
            try await wine.run(.script(script, ["--unattended", verb]), timeout: 1800)
        } catch WineError.executionFailed {
            throw WineError.winetricksFailed(trick: verb)
        }
        logger.notice("✓ Installed \(verb)")
    }
}
