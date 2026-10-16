//
//  SubprocessLineClassifier.swift
//  Shared
//
//  Picks the log level for one line of a subprocess's output from what the
//  line says, not from which pipe it came down. Wine, MoltenVK and ScummVM
//  all write routine chatter to stderr and real failures to stdout, so a
//  stream-based level marks hundreds of harmless lines as errors and buries
//  the few that matter.

import Foundation
import Logging

nonisolated enum SubprocessLineClassifier {

    /// The level to log `line` at. `fallback` is used when nothing about the
    /// line says what it is — conventionally `.notice` for stdout and
    /// `.warning` for stderr.
    static func level(for line: String, fallback: Logging.Logger.Level) -> Logging.Logger.Level {
        // Wine's debug classes: "0124:err:module:import_dll …".
        if let wineClass = wineDebugClass(of: line) {
            switch wineClass {
            case "err":
                return isKnownHarmlessWineError(line) ? .debug : .error
            case "warn", "fixme", "trace":
                return .debug
            default:
                break
            }
        }

        // Wine's crash reports and loader failures. These are the lines that
        // explain a game dying, so they are never quiet.
        if line.hasPrefix("wine: Unhandled") || line.contains("Unhandled page fault")
            || line.contains("Unhandled exception") || line.contains("Unhandled stack overflow") {
            return .critical
        }
        if line.hasPrefix("wine: ") && (line.contains("could not load") || line.contains("cannot find")
            || line.contains("failed") || line.contains("not found")) {
            return .error
        }
        // `wine start` / ShellExecute failures arrive on stdout.
        if line.hasPrefix("ShellExecuteEx failed") || line.hasPrefix("Application could not be started") {
            return .error
        }

        // Wine's sync backends announce themselves on every process start.
        if line.hasPrefix("msync:") || line.hasPrefix("esync:") || line.hasPrefix("fsync:") {
            return .debug
        }

        // MoltenVK: "[mvk-info] …", "[mvk-warn] …", "[mvk-error] …", and the
        // tab-indented detail lines that follow an info block.
        if line.hasPrefix("[mvk-error]") { return .error }
        if line.hasPrefix("[mvk-warn]") { return .warning }
        if line.hasPrefix("[mvk-info]") || line.hasPrefix("[mvk-debug]") || line.hasPrefix("\t") {
            return .debug
        }

        // ScummVM's own prefixes.
        if line.hasPrefix("ERROR:") { return .error }
        if line.hasPrefix("WARNING:") { return .warning }

        return fallback
    }

    /// `err` in "0124:err:module:…" — the debug class of a Wine debug line.
    private static func wineDebugClass(of line: String) -> Substring? {
        // Optional "pid:tid:" or "tid:" prefix of hex digits, then the class.
        let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        var index = 0
        while index < parts.count - 2,
              !parts[index].isEmpty,
              parts[index].unicodeScalars.allSatisfy({ hex.contains($0) }) {
            index += 1
        }
        let candidate = parts[index]
        return ["err", "warn", "fixme", "trace"].contains(candidate) ? candidate : nil
    }

    /// `err:` lines Wine prints on every healthy run. Kept at debug so
    /// turning the err class on by default costs nothing on a good launch.
    private static func isKnownHarmlessWineError(_ line: String) -> Bool {
        line.contains(":err:environ:init_peb") && line.contains("experimental wow64 mode")
    }
}
