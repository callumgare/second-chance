//
//  LogExporter.swift
//  Shared
//
//  Exports the in-memory LogStore ring to a file. Complete and lossless
//  where `log show` was not (the unified log drops .debug, keeps .info only
//  in a memory ring, and evicts under store pressure).

import Foundation
import AppKit
import UniformTypeIdentifiers

public enum LogExporter {

    /// Export the current LogStore ring to a file.
    ///
    /// Formatting up to 50k entries must not run on the main actor
    /// (SE-0461: a plain nonisolated async inherits the caller's executor,
    /// and LogActionButtons awaits this from a MainActor Task), hence the
    /// explicit detached task.
    public static func export(to url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let (entries, dropped) = LogStore.shared.snapshot()

            var sections: [String] = []
            if dropped > 0 {
                sections.append("[\(dropped) earlier entries were evicted from the \(50_000)-entry in-memory ring — enable the disk mirror for full-session capture]")
            }
            sections.append(contentsOf: entries.map { LogFormatter.full(entry: $0) })

            let text = sections.joined(separator: "\n") + "\n"
            do {
                try text.data(using: .utf8)?.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Default file name for log exports and the disk mirror, e.g.
    /// `second-chance-logs-2026-08-14-21-30-00.txt`.
    public static func defaultFileName(prefix: String = "second-chance") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(prefix)-logs-\(timestamp).txt"
    }

    /// Present an NSSavePanel and return the chosen URL, or nil if cancelled. Must be called on the main thread.
    public static func selectSaveURL(fileNamePrefix: String = "second-chance") -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Logs"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        panel.nameFieldStringValue = defaultFileName(prefix: fileNamePrefix)
        panel.allowedContentTypes = [.text]

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
