//
//  Wine.swift
//  Shared
//
//  One Wine and the prefix it runs in: where its programs are, the
//  environment they run with, and running them. Used by Second Chance's
//  build and by the wrapp.

import Foundation
import Logging

/// Second Chance's lines about running Wine: the same category as the
/// launcher's (WineProcess.swift).
private nonisolated let wineLogger = Logger(label: "au.gare.callum.second-chance.Shared.WineProcess")

/// A wrapp's Wine and the prefix it runs in.
nonisolated public struct Wine: Sendable {
    let wineDir: URL
    let binDir: URL
    let prefix: URL
    let frameworksDir: URL

    /// The Windows user name: whose folder under `drive_c/users` the saves are in.
    public static let username = "crossover"

    /// `WINEDEBUG` when `SECOND_CHANCE_WINEDEBUG` is unset: every channel
    /// off except the err class. See docs/logging.md.
    static let defaultWineDebug = "-all,err+all"

    /// The Wine bundled in `wrapp`, running in `prefix`: the wrapp's own
    /// unless given another.
    public init(wrapp: URL, prefix: URL? = nil) {
        self.wineDir = wrapp.appendingPathComponent("Contents/SharedSupport/wine")
        self.binDir = wineDir.appendingPathComponent("bin")
        self.prefix = prefix ?? wrapp.appendingPathComponent("Contents/SharedSupport/prefix")
        self.frameworksDir = wrapp.appendingPathComponent("Contents/Frameworks")
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
            "GST_PLUGIN_PATH": frameworksDir.appendingPathComponent("GStreamer.framework/Libraries/gstreamer-1.0").path,
            "WINETRICKS_FALLBACK_LIBRARY_PATH": dyldFallbackLibraryPath,
            "WINEBOOT_HIDE_DIALOG": "1",
            "CX_ROOT": wineDir.path,
            "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
            // MoltenVK logs at info by default: ~160 lines of extension and
            // GPU listings per launch. Warnings and errors still come through.
            "MVK_CONFIG_LOG_LEVEL": "2",
            "MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE": "1",
            "WINEESYNC": "1",
            "WINEMSYNC": "1",
            "MTL_HUD_ENABLED": "0",
            "MVK_CONFIG_FAST_MATH_ENABLED": "0",
            "DOTNET_EnableWriteXorExecute": "0"
        ]
    }

    /// What a Wine program runs with: ours over the parent's.
    public var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging(variables) { $1 }
    }

    /// `export NAME='value'` lines for `variables`, sorted: pasted into a
    /// shell, they run Wine by hand against this prefix. Wine's own folder
    /// is first on their PATH.
    public var shellExports: String {
        variables.sorted { $0.key < $1.key }
            .map { "export \($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
    }
}
