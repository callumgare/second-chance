//
//  LogFormatter.swift
//  Shared
//
//  Formatters for log entries at different verbosity levels.

import Foundation

/// Fields extracted from a line of an exported log file. File-scope (like
/// `Entry`) to avoid nested type inference issues under
/// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated struct LogLineFields: Equatable, Sendable {
    let time: String
    let level: String
    let category: String
    let message: String
}

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

    /// Parse one line of an exported log file — either the full format
    /// (from `full`: exports, disk mirror) or the compact format (from
    /// `compact`: stderr mirror). Full-format ISO timestamps are converted
    /// to local time-of-day (`HH:mm:ss.SSS`) so imported rows render the
    /// same Time column as live rows.
    ///
    /// Returns nil when the line carries no time/level/category prefix —
    /// e.g. a continuation of a multi-line message — or when the level token
    /// isn't a known swift-log level (guards against false positives on
    /// arbitrary text).
    nonisolated static func parse(line: String) -> LogLineFields? {
        if let match = try? fullLineRegex.firstMatch(in: line) {
            return makeFields(
                time: String(match.output.1),
                rawLevel: String(match.output.2),
                // The full format carries the complete subsystem label;
                // rows show only the trailing category component.
                category: extractCategory(from: String(match.output.3)),
                message: String(match.output.4)
            )
        }
        if let match = try? compactLineRegex.firstMatch(in: line) {
            return makeFields(
                time: String(match.output.1),
                rawLevel: String(match.output.2),
                category: String(match.output.3),
                message: String(match.output.4)
            )
        }
        return nil
    }

    // MARK: - Private

    /// Assemble parsed fields, rejecting unknown levels and converting
    /// ISO timestamps to local time-of-day.
    nonisolated private static func makeFields(time rawTime: String, rawLevel: String, category: String, message: String) -> LogLineFields? {
        let normalized = rawLevel.lowercased()
        guard knownLevels.contains(normalized) else { return nil }
        let time = localTime(fromISO: rawTime) ?? rawTime
        return LogLineFields(time: time, level: formatLevel(normalized), category: category, message: message)
    }

    /// `2026-02-16T00:00:00.000Z` → `10:00:00.000` (local time-of-day).
    nonisolated private static func localTime(fromISO iso: String) -> String? {
        guard let date = fullFormatter.date(from: iso) else { return nil }
        return timeFormatter.string(from: date)
    }

    nonisolated private static let knownLevels: Set<String> = [
        "trace", "debug", "info", "notice", "warning", "error", "critical",
    ]

    /// `<ISO8601>  <level>  <full label>  <message>` — labels carry no spaces,
    /// and fields are separated by runs of 2+ spaces.
    nonisolated private static let fullLineRegex = /^(\d{4}-\d{2}-\d{2}T[\d:.]+Z)\s{2,}(\S+)\s{2,}(\S+)\s{2,}(.*)$/

    /// `HH:mm:ss.SSS  <level>  <category>  <message>`.
    nonisolated private static let compactLineRegex = /^(\d{2}:\d{2}:\d{2}\.\d{3})\s{2,}(\S+)\s{2,}(\S+)\s{2,}(.*)$/
    
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
    
    // MARK: - Category

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