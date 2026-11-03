//
//  RunContext+Header.swift
//  Shared
//
//  The header every log starts with: RunContext's facts, Wine's settings
//  and the Mac's load.

import Foundation
import Logging

nonisolated extension RunContext {
    /// The lines of the header, without logging them.
    static func headerLines(extra: [(String, String)] = []) -> [String] {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let arch = processArchitecture
        let session = hasWindowServerSession
            ? "GUI session (\(launchdSession ?? "unknown"))"
            : "no GUI session (\(launchdSession ?? "unknown")) — Wine can't open windows here (run through `sc in-gui-session`)"
        let wineDebug = ProcessInfo.processInfo.environment["SECOND_CHANCE_WINEDEBUG"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Wine.defaultWineDebug

        var lines = [
            "\(name) \(version) (build \(build)), pid \(ProcessInfo.processInfo.processIdentifier), run \(runID)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(machineModel()), process \(arch)",
            "\(session); WINEDEBUG=\(wineDebug)",
            // A busy Mac is the likeliest cause of a slow or failed Wine start.
            "load: \(SystemLoad.read().map(\.summary) ?? "unknown (ps failed)")",
        ]
        lines += extra.map { "\($0.0): \($0.1)" }
        return lines
    }

    /// Log the header as one entry, so it reads as a block.
    public static func logHeader(_ logger: Logging.Logger, extra: [(String, String)] = []) {
        let lines = headerLines(extra: extra)
        logger.notice("━━━ \(lines[0]) ━━━\n\(lines.dropFirst().map { "  \($0)" }.joined(separator: "\n"))")
        if !hasWindowServerSession {
            logger.warning("No GUI session: Wine programs that open windows (installers, games) will fail")
        }
        if let load = SystemLoad.read(), load.isHeavy {
            logger.warning("The Mac is heavily loaded: \(load.summary). Wine may take minutes to start programs, or fail to")
        }
    }
}
