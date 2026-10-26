//
//  FailureReport.swift
//  Shared
//
//  A failure, as `FailureReporter` sends it: what failed, in fixed words of
//  ours, and the identifiers that place it — never a message, which can hold
//  a path. What a detailed report adds rides alongside and is dropped for a
//  basic one. docs/failure-reports.md has what each level sends.

import Foundation

/// How much one report says. The setting (`ReportLevel`) can also be
/// "ask each time"; a report, once sent, is one of these.
nonisolated enum ReportDetail: String, Sendable {
    case basic
    case detailed
}

/// What became of a failure, for the error screen to show.
nonisolated enum ReportOutcome: Equatable, Sendable {
    /// Sent, as Sentry event `eventID`.
    case sent(eventID: String, detail: ReportDetail)
    /// Nothing has failed before: the error screen asks how detailed a
    /// report to send, and holds its way out back until it is answered.
    /// Leaving without answering sends it basic (`FailureReporter.wait`).
    case askingHowDetailed
    /// The setting is Manual: the error screen asks what to send.
    case awaitingChoice
    /// The person chose not to send it.
    case declined
    /// Reporting is off in this run (a Debug build, a headless build, a test).
    case disabled

    /// The ID to quote, shortened as Sentry's issue view shows it.
    var shortID: String? {
        guard case .sent(let id, _) = self else { return nil }
        return String(id.prefix(8))
    }
}

nonisolated struct FailureReport: Sendable {
    /// Tells this failure from the next, for a screen still showing it.
    let id = UUID()
    /// What failed, in our own fixed words: "Building the wrapp", "Running the game".
    var what: String
    /// The error's identifier (`ErrorChain.identifier`) or the way the game
    /// ended (`quit-early`, `exit-code`, `signal`).
    var kind: String
    /// The stage it failed in (`LogContext`), from the stage names we set.
    var stage: String?
    /// The game's slug (`GameInfo.id`).
    var game: String?
    /// `disk`, `her-download` or `steam`.
    var source: String?
    /// `GameEngine`'s raw value.
    var engine: String?
    /// More identifiers worth filtering on: exit code, signal, underlying errors.
    var tags: [String: String] = [:]

    // Detailed reports only.

    /// The `FailureSummary` block, redacted before it is sent.
    var summary: String?
    /// The diagnostics bundle for this failure, once it is complete.
    var diagnostics: (@Sendable () async -> URL?)?

    init(what: String, kind: String, stage: String? = LogContext.stage.name, game: String? = nil,
         source: String? = nil, engine: String? = nil, tags: [String: String] = [:],
         summary: String? = nil, diagnostics: (@Sendable () async -> URL?)? = nil) {
        self.what = what
        self.kind = kind
        self.stage = stage.map(Self.stableStage)
        self.game = game
        self.source = source
        self.engine = engine
        self.tags = tags
        self.summary = summary
        self.diagnostics = diagnostics
    }

    /// A report for a thrown error: its identifier, and its underlying
    /// errors' as a tag.
    init(what: String, error: Error, game: String? = nil, source: String? = nil, engine: String? = nil,
         summary: String? = nil, diagnostics: (@Sendable () async -> URL?)? = nil) {
        var tags: [String: String] = [:]
        let underlying = ErrorChain.underlyingIdentifiers(error)
        if !underlying.isEmpty {
            tags["caused_by"] = underlying.joined(separator: " ← ")
        }
        if let ended = error as? ProgramExitError {
            if let exitCode = ended.exitCode { tags["exit_code"] = String(exitCode) }
            if let signal = ended.signal { tags["signal"] = SubprocessWatch.signalName(signal) }
        }
        self.init(what: what, kind: ErrorChain.identifier(error), game: game, source: source,
                  engine: engine, tags: tags, summary: summary, diagnostics: diagnostics)
    }

    /// The process (`app` or `wrapp`), what failed and how, and where: one
    /// Sentry issue per way of failing. The game is a tag, not part of
    /// this, so one Wine problem across many games stays one issue.
    func fingerprint(process: String) -> [String] {
        [process, what, kind, stage ?? "-"]
    }

    var title: String { "\(what): \(kind)" }

    /// The stage without the progress decoration a build's step names carry
    /// ("Detecting game title..."), so it groups.
    static func stableStage(_ stage: String) -> String {
        var result = stage
        while result.hasSuffix(".") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// An error saying how a program ended. Its exit code or signal goes in a
/// report's `exit_code` or `signal` tag, as a game run's does: a number,
/// which holds no path, and often the whole story (126: it couldn't be run
/// at all).
nonisolated protocol ProgramExitError: Error {
    var exitCode: Int32? { get }
    var signal: Int32? { get }
}

/// What may stay in an event, by detail level. Pure, so the rules can be
/// tested without Sentry; `FailureReporter` applies them in `beforeSend`.
nonisolated enum ReportScrubber {

    /// The keys a basic report keeps from each of Sentry's contexts; a
    /// context not named here is dropped whole.
    static let basicContextKeys: [String: Set<String>] = [
        "os": ["name", "version", "build", "kernel_version"],
        "device": ["arch", "model", "family", "processor_count", "simulator"],
        "app": ["app_name", "app_version", "app_build", "app_identifier"],
        "runtime": ["name", "version", "raw_description"],
        "failure": ["kind", "stage", "what", "caused_by"],
    ]

    static func contexts(_ contexts: [String: [String: Any]], detail: ReportDetail,
                         redactor: ReportRedactor) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (name, values) in contexts {
            switch detail {
            case .detailed:
                result[name] = values.mapValues { redactor.redact(value: $0) }
            case .basic:
                guard let keep = basicContextKeys[name] else { continue }
                result[name] = values.filter { keep.contains($0.key) }.mapValues { redactor.redact(value: $0) }
            }
        }
        return result
    }
}
