//
//  Wine.swift
//  WineKit
//
//  One Wine and the prefix it runs in: where its programs are, the
//  environment they run with, and running them. Used by Second Chance's
//  build and by the wrapp.

import Foundation
import Logging
import WrappLogging
import ProcessKit
import WrappFormat

/// Second Chance's lines about running Wine: the same category as the
/// launcher's (WineProcess.swift).
private nonisolated let wineLogger = Logger(label: "au.gare.callum.second-chance.Shared.WineProcess")

/// A wrapp's Wine and the prefix it runs in.
nonisolated public struct Wine: Sendable {
    let wineDir: URL
    let binDir: URL
    public let prefix: URL
    let frameworksDir: URL
    /// More variables for every program run through this Wine, beneath
    /// Second Chance's own: for a game a program the session started earlier
    /// starts, such as a Windows service, whose environment is the
    /// session's (`services.exe` passes its own on), not that of whatever
    /// asked it to act.
    public var sessionVariables: [String: String] = [:]
    /// What this Wine has that Second Chance would otherwise make up for, or
    /// may use (its module.yaml's `has:`, as the wrapp's lock recorded it):
    /// `msync`, `cocoa-start-wait`. Nil when that isn't known, as in a
    /// build's tree, whose lock (an update's) may be another Wine's: then
    /// everything is done as for a Wine with none of them, msync aside,
    /// which is asked for as before (docs/modules.md#what-an-engine-has).
    public var engineHas: Set<String>?

    /// The Windows user name: whose folder under `drive_c/users` the saves are in.
    public static let username = "crossover"

    /// `WINEDEBUG` when `SECOND_CHANCE_WINEDEBUG` is unset: every channel
    /// off except the err class. See docs/logging.md.
    public static let defaultWineDebug = "-all,err+all"

    /// The Wine bundled in `wrapp`, running in `prefix`: the wrapp's own
    /// unless given another.
    public init(wrapp: URL, prefix: URL? = nil, engineHas: Set<String>? = nil) {
        let layout = WrappLayout(app: wrapp)
        self.wineDir = layout.wine
        self.binDir = wineDir.appendingPathComponent("bin")
        self.prefix = prefix ?? layout.prefix
        self.frameworksDir = layout.frameworks
        self.engineHas = engineHas
    }

    /// Names in a module.yaml's `has:` that this code acts on.
    public enum Has {
        /// CrossOver's msync and esync (Sikarugir's), which WineHQ's builds
        /// don't have: `WINEMSYNC`/`WINEESYNC` are set only for a Wine that may.
        public static let msync = "msync"
        /// Wine waits for Cocoa to start for as long as it takes, so the
        /// cocoa start wait helper stands down.
        public static let cocoaStartWait = "cocoa-start-wait"
    }

    /// The variables Second Chance sets for Wine, and only those.
    public var variables: [String: String] {
        let dyldFallbackLibraryPath = [
            frameworksDir.appendingPathComponent("moltenvkcx").path,
            wineDir.appendingPathComponent("lib").path,
            wineDir.appendingPathComponent("lib/external").path,
            wineDir.appendingPathComponent("lib64").path,
            frameworksDir.appendingPathComponent("d3dmetal/external").path,
            frameworksDir.path,
            "/opt/wine/lib",
            frameworksDir.appendingPathComponent("GStreamer.framework/Libraries").path,
            "/usr/lib",
            "/usr/libexec",
            "/usr/lib/system",
            "/opt/X11/lib"
        ].joined(separator: ":")

        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""

        // Only Wine's err class by default: it costs a line or two on a
        // healthy run, and it is where Wine names the cause when something
        // fails (a DLL that won't load, no graphics driver outside the GUI
        // session). SECOND_CHANCE_WINEDEBUG replaces it with other channels
        // (e.g. "+seh,+d3d9"). Deliberately not plain WINEDEBUG, which a user
        // may have set in their shell for some other Wine.
        let wineDebug = ProcessInfo.processInfo.environment["SECOND_CHANCE_WINEDEBUG"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultWineDebug

        return [
            "WINEPREFIX": prefix.path,
            "WINE": binDir.appendingPathComponent("wine").path,
            "USER": Self.username,
            "WINEDEBUG": wineDebug,
            "PATH": "\(binDir.path):\(originalPath):/opt/local/bin:/opt/local/sbin",
            "DYLD_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            "GST_PLUGIN_PATH": gstreamerPlugins.path,
            // This copy's own plugin cache, not the user's shared one, which
            // every other wrapp's GStreamer left stale (GStreamerCache).
            "GST_REGISTRY": gstreamerRegistry.path,
            "WINETRICKS_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            // Only Sikarugir's 10.0 wineboot reads this (to keep its dialog
            // hidden); WineHQ's and wine-mac-binaries' builds don't.
            "WINEBOOT_HIDE_DIALOG": "1",
            // winemenubuilder turns each Start menu entry and file association
            // an installer makes into a Linux `.desktop` file in
            // ~/.local/share/applications and ~/.config/menus — outside the
            // wrapp, and of no use on a Mac. Winetricks adds its own overrides
            // to this rather than replacing it.
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
            // MoltenVK logs at info by default: ~160 lines of extension and
            // GPU listings per launch. Warnings and errors still come through.
            "MVK_CONFIG_LOG_LEVEL": "2",
            "MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE": "1",
            "MTL_HUD_ENABLED": "0",
            "MVK_CONFIG_FAST_MATH_ENABLED": "0",
            "DOTNET_EnableWriteXorExecute": "0"
        ].merging(mayHaveMsync ? Self.syncVariables() : [:]) { $1 }
            .merging(engineHasVariables) { $1 }
            .merging(sessionVariables) { ours, _ in ours }
    }

    /// GStreamer's plugins, which DirectShow and Media Foundation decode
    /// through (an MP3 through MCI): the engine's own when it brings GStreamer
    /// inside Wine (a WineHQ build for macOS), else the wrapper template's,
    /// in Contents/Frameworks (Sikarugir's).
    var gstreamerPlugins: URL {
        let own = wineDir.appendingPathComponent("lib/GStreamer.framework/Libraries/gstreamer-1.0")
        return FileManager.default.fileExists(atPath: own.path)
            ? own : frameworksDir.appendingPathComponent("GStreamer.framework/Libraries/gstreamer-1.0")
    }

    /// `WINEMSYNC` and `WINEESYNC`: how Wine's programs wait on each other
    /// without a round trip to wineserver. Both on, unless
    /// `SECOND_CHANCE_WINE_SYNC` picks `esync` (Wine's msync off) or `none`
    /// (both off, every wait through wineserver) — a debug switch, for telling
    /// a hang in them apart from other causes.
    static func syncVariables(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        switch environment["SECOND_CHANCE_WINE_SYNC"] {
        case "esync": ["WINEESYNC": "1", "WINEMSYNC": "0"]
        case "none": ["WINEESYNC": "0", "WINEMSYNC": "0"]
        default: ["WINEESYNC": "1", "WINEMSYNC": "1"]
        }
    }

    /// Whether this Wine may have msync and esync: unless it's known not to.
    var mayHaveMsync: Bool { engineHas?.contains(Has.msync) ?? true }

    /// `WINE_ENGINE_HAS`, what this Wine has, comma-separated, for the
    /// in-process helpers: one whose fix it has stands down
    /// (`helperEngineHas`). Unset when that isn't known.
    var engineHasVariables: [String: String] {
        guard let engineHas else { return [:] }
        return ["WINE_ENGINE_HAS": engineHas.sorted().joined(separator: ",")]
    }

    /// What a Wine program runs with: ours over the parent's, less the
    /// parent's `DYLD_*`. Those are the test host's under `xcodebuild test`
    /// (its injected libraries and framework paths), and loaded into Wine they
    /// changed what an installer did. Wine used to start through `/bin/sh`,
    /// which, being protected, never got them, so none ever reached Wine.
    /// Nor does the Big Fish test account (`BIG_FISH_EMAIL`, `BIG_FISH_PASSWORD`)
    /// a test build signs in with: Windows programs can read their environment.
    public var environment: [String: String] {
        ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") && !Self.withheld.contains($0.key) }
            .merging(variables) { $1 }
    }

    /// What a Wine program is never given from Second Chance's environment.
    static let withheld: Set<String> = ["BIG_FISH_EMAIL", "BIG_FISH_PASSWORD"]

    /// `export NAME='value'` lines for `variables`, sorted: pasted into a
    /// shell, they run Wine by hand against this prefix. Wine's own folder
    /// is first on their PATH.
    public var shellExports: String {
        variables.sorted { $0.key < $1.key }
            .map { "export \($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
    }
}
