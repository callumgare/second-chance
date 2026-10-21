//
//  ReportingPreferences.swift
//  Shared
//
//  How much a failure report may say, chosen once and shared by Second
//  Chance and every wrapp. Wrapps are bundles of their own, so this can't
//  live in UserDefaults: it is a small JSON file in Second Chance's
//  Application Support folder, read afresh at each failure so a change made
//  in Second Chance reaches wrapps that are already running.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

/// What a failure report contains — docs/failure-reports.md has the table.
nonisolated enum ReportLevel: String, Codable, CaseIterable, Sendable {
    /// Anonymised logs and diagnostics are attached.
    case detailed
    /// The version, the game and what failed; nothing else.
    case basic
    /// Ask at each failure: detailed, basic, or nothing.
    case manual
}

nonisolated struct ReportingPreferences: Codable, Equatable, Sendable {
    var level: ReportLevel = .basic
    /// Whether the first-failure prompt has been shown, in the app or any wrapp.
    var promptShown: Bool = false

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SecondChance", isDirectory: true)
    static let fileName = "failure-reporting.json"

    /// The saved preferences, or the defaults when there are none or they
    /// can't be read.
    static func load(from directory: URL = defaultDirectory) -> ReportingPreferences {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return ReportingPreferences() }
        do {
            return try JSONDecoder().decode(ReportingPreferences.self, from: Data(contentsOf: file))
        } catch {
            logger.warning("Can't read the failure report settings in \(file.path), using the defaults: \(error.localizedDescription)")
            return ReportingPreferences()
        }
    }

    /// Save, replacing the file whole so a reader never sees half of it.
    func save(to directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Load, change and save in one step, logging rather than throwing: a
    /// setting that fails to save is not worth interrupting anyone over.
    @discardableResult
    static func update(in directory: URL = defaultDirectory, _ change: (inout ReportingPreferences) -> Void) -> ReportingPreferences {
        var preferences = load(from: directory)
        change(&preferences)
        do {
            try preferences.save(to: directory)
        } catch {
            logger.error("Can't save the failure report settings: \(error.localizedDescription)")
        }
        return preferences
    }
}
