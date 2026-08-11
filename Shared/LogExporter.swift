//
//  LogExporter.swift
//  Shared
//
//  Exports unified log entries for the current process to a file via `log show`.

import Foundation
import AppKit
import UniformTypeIdentifiers

public enum LogExporter {

    /// Export the current process's Second Chance log entries to a file. Runs on a background thread.
    public static func export(to url: URL) async -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = [
                    "show",
                    "--predicate", "processIdentifier == \(pid) AND subsystem BEGINSWITH 'com.secondchance'",
                    "--style", "syslog",
                ]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    try data.write(to: url)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Present an NSSavePanel and return the chosen URL, or nil if cancelled. Must be called on the main thread.
    public static func selectSaveURL(fileNamePrefix: String = "second-chance") -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Logs"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(fileNamePrefix)-logs-\(timestamp).txt"
        panel.allowedContentTypes = [.text]

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

}
