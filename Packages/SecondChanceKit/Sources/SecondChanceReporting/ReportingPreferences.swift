//
//  ReportingPreferences.swift
//  Shared
//
//  How much a failure report may say, and whether success reports are sent,
//  chosen once and shared by Second Chance and every wrapp. Wrapps are
//  bundles of their own, so this can't live in UserDefaults: it is a small
//  JSON file in Second Chance's Application Support folder, read afresh at
//  each use so a change made in Second Chance reaches wrapps that are
//  already running.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

/// What a failure report contains — docs/failure-reports.md has the table.
nonisolated public enum ReportLevel: String, Codable, CaseIterable, Sendable {
    /// Anonymised logs and diagnostics are attached.
    case detailed
    /// The version, the game and what failed; nothing else.
    case basic
    /// Ask at each failure: detailed, basic, or nothing.
    case manual
    /// Send nothing, and don't ask. Only Settings chooses it: the
    /// first-failure question offers a basic or a detailed report.
    case off
}

nonisolated public struct ReportingPreferences: Codable, Equatable, Sendable {
    public var level: ReportLevel = .basic
    /// Whether the first-failure prompt has been shown, in the app or any wrapp.
    public var promptShown: Bool = false
    /// Whether builds and launches may be counted (`SuccessReporter`); nil
    /// until the person has been asked, after their first successful build.
    public var successReports: Bool?

    /// The detail a report is sent at without asking anyone; nil when the
    /// setting asks first (Manual), or nobody has answered the first-failure
    /// question yet. For a failure with no screen to ask on.
    public var detailWithoutAsking: ReportDetail? {
        guard promptShown else { return nil }
        switch level {
        case .manual, .off: return nil
        case .basic: return .basic
        case .detailed: return .detailed
        }
    }

    public init(level: ReportLevel = .basic, promptShown: Bool = false, successReports: Bool? = nil) {
        self.level = level
        self.promptShown = promptShown
        self.successReports = successReports
    }

    private enum CodingKeys: String, CodingKey {
        case level, promptShown, successReports, off
    }

    /// Read key by key, so a file missing one (an older or newer version's)
    /// keeps what it does say rather than failing whole.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decodeIfPresent(ReportLevel.self, forKey: .level) ?? .basic
        if try container.decodeIfPresent(Bool.self, forKey: .off) == true {
            level = .off
        }
        promptShown = try container.decodeIfPresent(Bool.self, forKey: .promptShown) ?? false
        successReports = try container.decodeIfPresent(Bool.self, forKey: .successReports)
    }

    /// Off is saved as Manual with `off` beside it. Wrapps built by an older
    /// Second Chance read the same file and know no `off` level: one they
    /// can't read would leave them sending at their defaults, where Manual
    /// leaves them asking first.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level == .off ? .manual : level, forKey: .level)
        if level == .off { try container.encode(true, forKey: .off) }
        try container.encode(promptShown, forKey: .promptShown)
        try container.encodeIfPresent(successReports, forKey: .successReports)
    }

    /// The most private setting: ask before sending anything, and count
    /// nothing. What a settings file that can't be read stands for, since
    /// the person may have chosen exactly that.
    static let mostPrivate = ReportingPreferences(level: .manual, promptShown: true, successReports: false)

    /// The answer to the first-failure question: send at `detail` from now on.
    mutating func answerFirstQuestion(_ detail: ReportDetail) {
        level = detail == .detailed ? .detailed : .basic
        promptShown = true
    }

    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SecondChance", isDirectory: true)
    static let fileName = "failure-reporting.json"

    /// The saved preferences; the defaults when there are none; and the
    /// most private setting when they can't be read, since sending on the
    /// defaults could override someone's choice to be asked first.
    public static func load(from directory: URL = defaultDirectory) -> ReportingPreferences {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return ReportingPreferences() }
        do {
            return try JSONDecoder().decode(ReportingPreferences.self, from: Data(contentsOf: file))
        } catch {
            logger.warning("Can't read the failure report settings in \(file.path), so asking before sending anything: \(error.localizedDescription)")
            return mostPrivate
        }
    }

    /// Save, replacing the file whole so a reader never sees half of it.
    func save(to directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Posted to every process (a distributed notification) when the
    /// settings are saved, so an error screen in Second Chance or any wrapp
    /// still asking about a report can follow a choice made in Settings.
    static let changedNotification = Notification.Name("au.gare.callum.second-chance.ReportingPreferencesChanged")

    /// Load, change and save in one step, logging rather than throwing: a
    /// setting that fails to save is not worth interrupting anyone over.
    @discardableResult
    public static func update(in directory: URL = defaultDirectory, _ change: (inout ReportingPreferences) -> Void) -> ReportingPreferences {
        var preferences = load(from: directory)
        change(&preferences)
        do {
            try preferences.save(to: directory)
            DistributedNotificationCenter.default().postNotificationName(changedNotification, object: directory.path,
                                                                         userInfo: nil, deliverImmediately: true)
        } catch {
            logger.error("Can't save the failure report settings: \(error.localizedDescription)")
        }
        return preferences
    }
}
