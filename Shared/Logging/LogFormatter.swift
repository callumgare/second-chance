//
//  LogFormatter.swift
//  Shared
//
//  Formatters for log entries at different verbosity levels.

import Foundation

/// Log formatting styles.
nonisolated struct LogFormatter {
    
    /// Compact format for terminal and window display.
    /// Format: `HH:mm:ss.SSS  notice  GameDetector  <message>`
    /// Short category because messages carry their own structure.
    nonisolated static func compact(entry: Entry) -> String {
        return "\(time(entry: entry))  \(formatLevel(entry.level))  \(extractCategory(from: entry.label))  \(entry.message)"
    }

    /// Time component of the compact format (`HH:mm:ss.SSS`).
    nonisolated static func time(entry: Entry) -> String {
        timeFormatter.string(from: entry.timestamp)
    }
    
    /// Full format for export and disk mirror.
    /// One line per entry: `<ISO8601 timestamp>  <level>  <full label>  <message>`
    /// with an attached error appended as ` — Error: <error>`.
    ///
    /// Messages that themselves contain newlines (step dividers, Wine output)
    /// naturally span lines — the timestamp/level/label prefix identifies the
    /// entry. Truncation is already marked in-band by LogStore
    /// (`…[truncated N bytes]`), so no separate marker line is emitted.
    nonisolated static func full(entry: Entry) -> String {
        var line = "\(fullFormatter.string(from: entry.timestamp))  \(entry.level)  \(entry.label)  \(entry.message)"
        if let error = entry.error {
            line += " — Error: \(error)"
        }
        return line
    }
    
    // MARK: - Private
    
    /// Time formatter for compact display (HH:mm:ss.SSS).
    nonisolated private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    
    /// Full ISO8601 formatter for exports (`2026-08-16T03:42:59.167Z`).
    /// `.withInternetDateTime` carries the dash/colon separators the raw
    /// option list omits (without `.withColonSeparatorInTime` the time
    /// renders as `034259.167Z`).
    nonisolated private static let fullFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    /// Extract the category (last component) from a label like "au.gare.callum.second-chance.SecondChance.GameDetector".
    nonisolated static func extractCategory(from label: String) -> String {
        if let lastDot = label.lastIndex(of: ".") {
            return String(label[label.index(after: lastDot)...])
        }
        return label
    }
    
    /// Format level with consistent width.
    nonisolated static func formatLevel(_ level: String) -> String {
        // swift-log level names are lowercase, but we may get mixed case
        let normalized = level.lowercased()
        switch normalized {
        case "trace", "debug":
            return "debug"
        case "info", "notice":
            return "notice"
        case "warning":
            return "warning"
        case "error":
            return "error"
        case "critical":
            return "critical"
        default:
            return normalized
        }
    }
}