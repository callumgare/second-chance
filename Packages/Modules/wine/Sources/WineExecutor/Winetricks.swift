//
//  Winetricks.swift
//  WineExecutor
//
//  Installing winetricks verbs into a prefix. Winetricks is the wine
//  module's, carried by its package, not by wrapps, so only a build runs it.

import Foundation
import Logging
import WineKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Winetricks")

public nonisolated struct Winetricks: Sendable {
    let wine: Wine
    let script: URL?
    /// Programs winetricks needs that macOS hasn't (cabextract), first on
    /// its PATH: the wine engine's `build-tools`, which no wrapp gets.
    let tools: URL?

    /// The winetricks the wine module carries (`Bundle.module`'s accessor is
    /// the main actor's, as this package's code is by default).
    public static func bundledScript() async -> URL? {
        await MainActor.run { Bundle.module.url(forResource: "winetricks", withExtension: nil) }
    }

    /// The winetricks the wine module carries, in an app that has this
    /// package's resources: `WineModule_WineExecutor.bundle` in its Resources.
    public static func bundledScript(in app: Bundle) -> URL? {
        app.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("WineModule_WineExecutor.bundle")) }?
            .url(forResource: "winetricks", withExtension: nil)
    }

    /// `script` nil for the one the module carries.
    public init(wine: Wine, script: URL? = nil, tools: URL? = nil) {
        self.wine = wine
        self.script = script
        self.tools = tools
    }

    /// Install `verb`, as the wine module's prefix set-up names it
    /// (`WINE.WINETRICKS`). Logged and stopped like any other Wine
    /// program (`Wine.run`); winetricks failing throws `winetricksFailed`.
    public func install(_ verb: String) async throws {
        guard let script = await resolvedScript() else { throw WineError.winetricksNotFound }
        do {
            // cnc_ddraw downloads its release the first time, so allow for a
            // slow connection.
            let path = tools.map { ["PATH": "\($0.path):\(wine.environment["PATH"] ?? "/usr/bin:/bin")"] } ?? [:]
            try await wine.run(.script(script, ["--unattended", verb]), environment: path, timeout: 1800)
        } catch WineError.executionFailed {
            throw WineError.winetricksFailed(trick: verb)
        }
        logger.notice("✓ Installed \(verb)")
    }

    func resolvedScript() async -> URL? {
        if let script { return script }
        return await Self.bundledScript()
    }
}
