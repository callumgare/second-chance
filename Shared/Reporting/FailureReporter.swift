//
//  FailureReporter.swift
//  Shared
//
//  Sends failures and crashes to Sentry, at the detail the person chose
//  (`ReportingPreferences`). Second Chance and every wrapp start it straight
//  after logging; WrappPuppeteer compiles Shared too but doesn't link Sentry,
//  so everything that touches the SDK is behind `FAILURE_REPORTING`, which
//  only those two targets define. docs/failure-reports.md has the whole story.

import Foundation
import Logging
import os
#if FAILURE_REPORTING
import Sentry
#endif

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

nonisolated enum FailureReporter {

    enum Process: String, Sendable {
        case app
        case wrapp
    }

    /// Where reports go. Not a secret: a DSN can only send events, and every
    /// copy of the app carries it. Empty sends nothing; set
    /// `SECOND_CHANCE_SENTRY_DSN` to try a build against another project.
    static let releaseDSN = ""

    private struct State {
        var process: Process?
        var started = false
        /// What to do with a crash the SDK finds from the previous run:
        /// send it at this detail, or drop it (nil).
        var crashDetail: ReportDetail?
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var isEnabled: Bool { state.withLock { $0.started } }

    // MARK: Start

    /// Why reporting must stay off in this run, or nil when it may start.
    /// A Debug build reports nothing (we'd be reporting our own work in
    /// progress), nor does a headless build or a test — `NON_INTERACTIVE`
    /// covers the integration tests, and WrappPuppeteer marks the wrapps it
    /// drives with `SECOND_CHANCE_PUPPET_DIR`. `SECOND_CHANCE_REPORTING=1`
    /// or `0` overrides all of these.
    static func disabledReason(environment env: [String: String], isDebugBuild: Bool, dsn: String) -> String? {
        if dsn.isEmpty { return "no Sentry DSN set" }
        if let forced = env["SECOND_CHANCE_REPORTING"] {
            return forced == "1" ? nil : "SECOND_CHANCE_REPORTING=\(forced)"
        }
        if env["NON_INTERACTIVE"] == "true" { return "headless build" }
        if env["SECOND_CHANCE_PUPPET_DIR"] != nil { return "driven by WrappPuppeteer" }
        if env["XCTestConfigurationFilePath"] != nil { return "running tests" }
        if isDebugBuild { return "Debug build" }
        return nil
    }

    static var dsn: String {
        let override = ProcessInfo.processInfo.environment["SECOND_CHANCE_SENTRY_DSN"] ?? ""
        return override.isEmpty ? releaseDSN : override
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Start the SDK, unless this run mustn't report. Call straight after
    /// `AppLogging.bootstrap` and before `CrashMarker.install`, so the crash
    /// marker's signal handler runs first and hands on to Sentry's.
    ///
    /// - Parameters:
    ///   - crashDetail: What to do with a crash from the previous run; by
    ///     default, what the setting says (Manual drops it — the caller asks
    ///     first and passes the answer).
    static func start(process: Process, game: String? = nil, engine: String? = nil,
                      crashDetail: ReportDetail?? = nil) {
        state.withLock { $0.process = process }
        if let reason = disabledReason(environment: ProcessInfo.processInfo.environment,
                                       isDebugBuild: isDebugBuild, dsn: dsn) {
            logger.debug("Failure reports are off: \(reason)")
            return
        }
        #if FAILURE_REPORTING
        let resolvedCrashDetail = crashDetail ?? defaultCrashDetail(for: ReportingPreferences.load().level)
        state.withLock { $0.crashDetail = resolvedCrashDetail }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "second-chance@\(version)+\(build)"
            options.dist = build
            options.environment = isDebugBuild ? "development" : "production"
            options.sendDefaultPii = false

            // Failures and crashes, nothing else: no sessions, no tracing,
            // no automatic breadcrumbs or network capture.
            options.enableCrashHandler = true
            options.enableUncaughtNSExceptionReporting = true
            options.enableAutoSessionTracking = false
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = nil
            options.enableAppHangTracking = false
            options.enableMetricKit = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableFileIOTracing = false
            options.enableSwizzling = false
            options.sendClientReports = false
            options.attachStacktrace = false
            options.maxBreadcrumbs = 0

            options.beforeSend = { event in scrub(event) }
        }
        SentrySDK.configureScope { scope in
            scope.setTag(value: process.rawValue, key: "process")
            if let game { scope.setTag(value: game, key: "game") }
            if let engine { scope.setTag(value: engine, key: "engine") }
        }
        state.withLock { $0.started = true }
        logger.notice("Failure reports are on (\(ReportingPreferences.load().level.rawValue))")
        #endif
    }

    /// What a crash from the previous run is sent as when nobody was asked.
    static func defaultCrashDetail(for level: ReportLevel) -> ReportDetail? {
        switch level {
        case .detailed: return .detailed
        case .basic: return .basic
        case .manual: return nil
        }
    }

    /// Name the game a build is working on, so a crash mid-build says which.
    static func setGame(_ game: String?, source: String? = nil, engine: String? = nil) {
        #if FAILURE_REPORTING
        guard isEnabled else { return }
        SentrySDK.configureScope { scope in
            if let game { scope.setTag(value: game, key: "game") } else { scope.removeTag(key: "game") }
            if let source { scope.setTag(value: source, key: "source") } else { scope.removeTag(key: "source") }
            if let engine { scope.setTag(value: engine, key: "engine") } else { scope.removeTag(key: "engine") }
        }
        #endif
    }

    // MARK: Report

    /// Report a failure at the detail the setting asks for. With the setting
    /// at Manual nothing is sent: the error screen asks, then calls `send`.
    static func report(_ report: FailureReport) async -> ReportOutcome {
        guard isEnabled else { return .disabled }
        switch ReportingPreferences.load().level {
        case .manual: return .awaitingChoice
        case .basic: return await send(report, detail: .basic)
        case .detailed: return await send(report, detail: .detailed)
        }
    }

    /// Send `report` at `detail`, whatever the setting.
    static func send(_ report: FailureReport, detail: ReportDetail) async -> ReportOutcome {
        #if FAILURE_REPORTING
        guard isEnabled, let process = state.withLock({ $0.process }) else { return .disabled }
        let redactor = ReportRedactor.current

        let event = Event(level: .error)
        event.message = SentryMessage(formatted: report.title)
        event.fingerprint = report.fingerprint(process: process.rawValue)

        var failure: [String: Any] = ["what": report.what, "kind": report.kind]
        if let stage = report.stage { failure["stage"] = stage }
        if let causedBy = report.tags["caused_by"] { failure["caused_by"] = causedBy }

        let id = SentrySDK.capture(event: event) { scope in
            scope.setTag(value: detail.rawValue, key: "report_detail")
            if let game = report.game { scope.setTag(value: game, key: "game") }
            if let source = report.source { scope.setTag(value: source, key: "source") }
            if let engine = report.engine { scope.setTag(value: engine, key: "engine") }
            if let stage = report.stage { scope.setTag(value: stage, key: "stage") }
            for (key, value) in report.tags { scope.setTag(value: value, key: key) }
            scope.setContext(value: failure, key: "failure")
            if detail == .detailed, let summary = report.summary {
                scope.setExtra(value: redactor.redact(summary), key: "summary")
            }
        }
        logger.notice("Sent a \(detail.rawValue) failure report: \(id.sentryIdString)")
        return .sent(eventID: id.sentryIdString, detail: detail)
        #else
        return .disabled
        #endif
    }

    /// Send what the person wrote about a failure, tied to its report.
    static func sendComment(_ message: String, email: String?, about eventID: String) {
        #if FAILURE_REPORTING
        guard isEnabled, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedback = SentryFeedback(
            message: message,
            name: nil,
            email: (email?.isEmpty ?? true) ? nil : email,
            source: .custom,
            associatedEventId: SentryId(uuidString: eventID)
        )
        SentrySDK.capture(feedback: feedback)
        logger.notice("Sent a comment on failure report \(eventID)")
        #endif
    }

    /// Crash on purpose, to check that a crash reaches the crash marker,
    /// macOS's crash report and Sentry (Debug Settings → Crash Now).
    static func crashForTesting() -> Never {
        logger.critical("Crashing on purpose to test crash reporting")
        LogStore.shared.flush()
        fatalError("Crash requested to test crash reporting")
    }

    /// Wait for queued reports to go, before a process exits on purpose.
    static func flush(timeout: TimeInterval = 3) {
        #if FAILURE_REPORTING
        guard isEnabled else { return }
        SentrySDK.flush(timeout: timeout)
        #endif
    }

    #if FAILURE_REPORTING
    // MARK: Scrubbing

    /// The last word on what leaves the Mac. Our own reports say their
    /// detail in `report_detail`; anything without it the SDK made itself —
    /// a crash from the previous run, an uncaught exception — and goes at
    /// `crashDetail`, or not at all.
    private static func scrub(_ event: Event) -> Event? {
        let detail: ReportDetail
        if let tagged = event.tags?["report_detail"].flatMap(ReportDetail.init(rawValue:)) {
            detail = tagged
        } else if let crash = state.withLock({ $0.crashDetail }) {
            detail = crash
            event.tags = (event.tags ?? [:]).merging(["report_detail": crash.rawValue]) { $1 }
        } else {
            logger.notice("Not sending the SDK's \(event.level == .fatal ? "crash" : "event") report: reports are set to ask first")
            return nil
        }
        let redactor = ReportRedactor.current

        event.serverName = nil
        event.request = nil
        event.modules = nil
        event.user = event.user?.userId.map { User(userId: $0) }
        event.context = ReportScrubber.contexts(event.context ?? [:], detail: detail, redactor: redactor)
        event.tags = event.tags?.mapValues { redactor.redact($0) }
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: redactor.redact(message))
        }
        for exception in event.exceptions ?? [] {
            exception.value = exception.value.map { redactor.redact($0) }
            redact(exception.stacktrace, with: redactor)
        }
        for thread in event.threads ?? [] {
            thread.name = thread.name.map { redactor.redact($0) }
            redact(thread.stacktrace, with: redactor)
        }
        redact(event.stacktrace, with: redactor)
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map { redactor.redact($0) }
        }

        switch detail {
        case .basic:
            event.extra = nil
            event.breadcrumbs = nil
        case .detailed:
            event.extra = event.extra.map { redactor.redact(value: $0) as? [String: Any] ?? [:] }
            for crumb in event.breadcrumbs ?? [] {
                crumb.message = crumb.message.map { redactor.redact($0) }
                crumb.data = crumb.data.map { redactor.redact(value: $0) as? [String: Any] ?? [:] }
            }
        }
        return event
    }

    private static func redact(_ stacktrace: SentryStacktrace?, with redactor: ReportRedactor) {
        for frame in stacktrace?.frames ?? [] {
            frame.package = frame.package.map { redactor.redact($0) }
            frame.fileName = frame.fileName.map { redactor.redact($0) }
        }
    }
    #endif
}
