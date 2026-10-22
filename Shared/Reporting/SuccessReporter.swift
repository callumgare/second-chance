//
//  SuccessReporter.swift
//  Shared
//
//  Counts builds and game launches, and how each ended, as Sentry metrics,
//  for people who said yes to success reports — so failures have something
//  to be measured against and we can tell which games are known to work.
//  It rides on the SDK `FailureReporter` started, and on its gating: off in
//  Debug, headless, test and WrappPuppeteer runs. docs/failure-reports.md
//  has what is sent.

import Foundation
import Logging
#if FAILURE_REPORTING
@preconcurrency import Sentry
#endif

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

/// One build or launch, as a success report counts it: fixed identifiers
/// only, never a message.
nonisolated struct SuccessReport: Sendable, Equatable {
    enum Event: String, Sendable {
        case build
        case launch
    }

    static let ok = "ok"

    var event: Event
    /// `ok`, or the failure's kind: an `ErrorChain.identifier` for a build,
    /// the way the game ended for a launch.
    var outcome: String
    /// The game's slug (`GameInfo.id`).
    var game: String?
    /// `disk`, `her-download` or `steam`.
    var source: String?
    /// `GameEngine`'s raw value.
    var engine: String?

    var attributes: [String: String] {
        var attributes = ["outcome": outcome]
        attributes["game"] = game
        attributes["source"] = source
        attributes["engine"] = engine
        return attributes
    }
}

nonisolated enum SuccessReporter {

    /// The attributes a metric may leave with. The SDK adds the scope's
    /// tags, the user's installation ID and the device's details before
    /// `beforeSendMetric`; everything not named here is dropped there, so a
    /// success report says which game and how it went, and nothing about
    /// whose Mac it was.
    static let allowedAttributes: Set<String> = [
        "game", "source", "engine", "outcome",
        "sentry.release", "sentry.environment", "sentry.sdk.name", "sentry.sdk.version",
        "os.name", "os.version",
    ]

    /// Whether to count anything: only when reporting is on in this run and
    /// the person said yes.
    static func shouldRecord(_ preferences: ReportingPreferences, reportingEnabled: Bool) -> Bool {
        reportingEnabled && preferences.successReports == true
    }

    /// `attributes` cut down to `allowedAttributes`.
    static func allowed<Value>(_ attributes: [String: Value]) -> [String: Value] {
        attributes.filter { allowedAttributes.contains($0.key) }
    }

    static func record(_ report: SuccessReport) {
        guard shouldRecord(ReportingPreferences.load(), reportingEnabled: FailureReporter.isEnabled) else { return }
        #if FAILURE_REPORTING
        SentrySDK.metrics.count(key: report.event.rawValue, value: 1, attributes: report.attributes)
        logger.debug("Counted a \(report.event.rawValue) for the success reports: \(report.outcome)")
        #endif
    }

    #if FAILURE_REPORTING
    /// `beforeSendMetric`: drops a metric the person no longer wants sent —
    /// they may have changed their mind since it was buffered — and cuts the
    /// rest down to `allowedAttributes`.
    static func scrub(_ metric: SentryMetric) -> SentryMetric? {
        guard ReportingPreferences.load().successReports == true else { return nil }
        var metric = metric
        metric.attributes = allowed(metric.attributes)
        return metric
    }
    #endif
}
