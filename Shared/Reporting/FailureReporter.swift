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

    /// Where reports go: `SentryDSN` in the Info.plist, written at build
    /// time from `SENTRY_DSN` in the repo's `.env` (stamp-sentry-dsn.sh). A
    /// build without one — a fork's, a contributor's — sends nothing. Not a
    /// secret: a DSN can only send events, and every copy carries it.
    static var bundledDSN: String {
        (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private struct State {
        var process: Process?
        var started = false
        /// Where this process keeps a log per run, for a detailed report of
        /// the previous run's crash.
        var runLogs: (directory: URL, prefix: String)?
        /// The SDK's own events already held back for `previousRunCrashed`.
        /// Each is held back once: should one come round again untagged,
        /// it is dropped rather than sent round for ever.
        var heldBack: Set<String> = []
        /// A first failure whose screen is asking how detailed to send it.
        /// Sent basic if the process leaves before it is answered.
        var unanswered: FailureReport?
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    /// Entered while a report is being put together and handed to the SDK,
    /// so a process on its way out can wait for it.
    private static let sending = DispatchGroup()

    static var isEnabled: Bool { state.withLock { $0.started } }

    /// Whether Sentry's crash handler is installed in this run, in which
    /// case `CrashMarker` installs none (see `CrashMarker.arm`).
    static var handlesCrashes: Bool { isEnabled }

    // MARK: Start

    /// Why reporting must stay off in this run, or nil when it may start.
    /// A Debug build reports nothing (we'd be reporting our own work in
    /// progress), nor does a headless build or a test — `NON_INTERACTIVE`
    /// covers the integration tests, and WrappPuppeteer marks the wrapps it
    /// drives with `SECOND_CHANCE_PUPPET_DIR`. `SECOND_CHANCE_REPORTING=1`
    /// or `0` overrides all of these.
    static func disabledReason(environment env: [String: String], isDebugBuild: Bool, dsn: String) -> String? {
        if dsn.isEmpty { return "built without a Sentry DSN" }
        if let forced = env["SECOND_CHANCE_REPORTING"] {
            return forced == "1" ? nil : "SECOND_CHANCE_REPORTING=\(forced)"
        }
        if env["NON_INTERACTIVE"] == "true" { return "headless build" }
        if env["SECOND_CHANCE_PUPPET_DIR"] != nil { return "driven by WrappPuppeteer" }
        if env["XCTestConfigurationFilePath"] != nil { return "running tests" }
        if isDebugBuild { return "Debug build" }
        return nil
    }

    /// `SECOND_CHANCE_SENTRY_DSN` overrides the built-in one, to try a
    /// build against another project.
    static var dsn: String {
        let override = ProcessInfo.processInfo.environment["SECOND_CHANCE_SENTRY_DSN"] ?? ""
        return override.isEmpty ? bundledDSN : override
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Start the SDK, unless this run mustn't report. Call straight after
    /// `AppLogging.bootstrap`, and before `CrashMarker.arm()`, which leaves
    /// crashes to Sentry when it is on.
    static func start(process: Process, game: String? = nil, engine: String? = nil) {
        state.withLock { $0.process = process }
        if let reason = disabledReason(environment: ProcessInfo.processInfo.environment,
                                       isDebugBuild: isDebugBuild, dsn: dsn) {
            logger.debug("Failure reports are off: \(reason)")
            return
        }
        #if FAILURE_REPORTING
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
            // ReportBundle keeps its zip well under this.
            options.maxAttachmentSize = 20 * 1024 * 1024

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

    /// Where this process keeps a log per run (`RotatingLogFile`), so a
    /// detailed report of a crash can carry the log of the run that crashed.
    static func setRunLogs(in directory: URL, prefix: String) {
        state.withLock { $0.runLogs = (directory, prefix) }
    }

    /// What a crash from the previous run is sent as without asking: the
    /// setting's detail, or nil when the setting is to ask.
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

    /// Report a failure at the detail the setting asks for. Nothing is sent
    /// for the first failure (the error screen asks how detailed to send it)
    /// or with the setting at Manual (it asks whether to): the screen calls
    /// `send` with the answer.
    static func report(_ report: FailureReport) async -> ReportOutcome {
        guard isEnabled else { return .disabled }
        let preferences = ReportingPreferences.load()
        if !preferences.promptShown {
            state.withLock { $0.unanswered = report }
            return .askingHowDetailed
        }
        switch preferences.level {
        case .manual: return .awaitingChoice
        case .basic: return await send(report, detail: .basic)
        case .detailed: return await send(report, detail: .detailed)
        }
    }

    /// Send `report` at `detail`, whatever the setting.
    static func send(_ report: FailureReport, detail: ReportDetail) async -> ReportOutcome {
        #if FAILURE_REPORTING
        guard isEnabled else { return .disabled }
        answered(report)
        sending.enter()
        defer { sending.leave() }
        return await sendNow(report, detail: detail)
        #else
        return .disabled
        #endif
    }

    /// `send`, started before this returns: the report counts as answered
    /// and as being sent at once, so a quit straight after neither sends it
    /// a second time nor leaves before it has gone.
    static func sendInBackground(_ report: FailureReport, detail: ReportDetail) -> Task<ReportOutcome, Never> {
        guard isEnabled else { return Task { .disabled } }
        answered(report)
        sending.enter()
        return Task.detached {
            defer { sending.leave() }
            return await sendNow(report, detail: detail)
        }
    }

    private static func sendNow(_ report: FailureReport, detail: ReportDetail) async -> ReportOutcome {
        #if FAILURE_REPORTING
        guard let process = state.withLock({ $0.process }) else { return .disabled }
        let redactor = ReportRedactor.current

        let event = Event(level: .error)
        event.message = SentryMessage(formatted: report.title)
        event.fingerprint = report.fingerprint(process: process.rawValue)

        var failure: [String: Any] = ["what": report.what, "kind": report.kind]
        if let stage = report.stage { failure["stage"] = stage }
        if let causedBy = report.tags["caused_by"] { failure["caused_by"] = causedBy }

        // A detailed report carries the log and any diagnostics bundle,
        // redacted and zipped in a folder of its own, removed once the SDK
        // has stored the event (it reads the file as it does).
        var attachment: Attachment?
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-chance-report-\(report.id.uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        if detail == .detailed {
            let diagnostics = await report.diagnostics?()
            do {
                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                let zip = try ReportBundle.make(log: LogExporter.render(), diagnostics: diagnostics,
                                                redactor: redactor, in: workDirectory)
                attachment = Attachment(path: zip.path, filename: "failure-report.zip", contentType: "application/zip")
            } catch {
                logger.error("Couldn't attach the logs to the failure report: \(ErrorChain.describe(error))")
            }
        }

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
            if let attachment { scope.addAttachment(attachment) }
        }
        logger.notice("Sent a \(detail.rawValue) failure report: \(id.sentryIdString)")
        return .sent(eventID: id.sentryIdString, detail: detail)
        #else
        return .disabled
        #endif
    }

    /// The person chose to send nothing.
    static func decline(_ report: FailureReport) {
        answered(report)
    }

    private static func answered(_ report: FailureReport) {
        state.withLock { if $0.unanswered?.id == report.id { $0.unanswered = nil } }
    }

    /// Posted, on the main queue, when a report is sent basic because the
    /// person quit without answering how detailed to send it; the object is
    /// the report's `id`, for its error screen to show it being sent.
    static let sendingUnansweredOnQuit = Notification.Name("FailureReporterSendingUnansweredOnQuit")

    /// Leaving with the first-failure question unanswered: send it basic.
    @discardableResult
    private static func sendUnansweredAsBasic() -> Task<ReportOutcome, Never>? {
        guard let report = state.withLock({ $0.unanswered }) else { return nil }
        logger.notice("Leaving before choosing how detailed a report to send: sending it basic")
        let task = sendInBackground(report, detail: .basic)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: sendingUnansweredOnQuit, object: report.id)
        }
        return task
    }

    /// For `applicationShouldTerminate`: when the first-failure question
    /// is unanswered, send the report basic with the error screen saying
    /// so, then quit again — `then` runs once it has gone. Returns whether
    /// it did, in which case the quit should be cancelled for now.
    ///
    /// `then` runs inside a main-queue job, so it must schedule the quit
    /// (`NSApp.perform(_:with:afterDelay:)`), not call `terminate` itself:
    /// a quit that waits for cleanup (`.terminateLater`) is answered from
    /// the main queue, which this job would be holding, and would wait for
    /// itself for ever.
    @MainActor
    static func sendUnansweredBeforeQuitting(then quitAgain: @escaping @MainActor () -> Void) -> Bool {
        guard let task = sendUnansweredAsBasic() else { return false }
        let started = Date()
        Task.detached {
            _ = await task.value
            flush()
            // Not a wait for anything: a basic report usually goes in a
            // fraction of a second, and the screen saying it is being sent
            // should stay up long enough to read rather than flash.
            let shown = Date().timeIntervalSince(started)
            if shown < 1 { try? await Task.sleep(for: .seconds(1 - shown)) }
            await MainActor.run { quitAgain() }
        }
        return true
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

    /// Report, and wait for it to be queued and sent, for a process about to
    /// exit. Detached, so it can't wait on the thread that's blocked here.
    static func reportAndWait(_ report: FailureReport, timeout: TimeInterval = 15) {
        guard isEnabled else { return }
        wait(for: Task.detached { await FailureReporter.report(report) }, timeout: timeout)
    }

    /// Wait for a report already under way, and any other being sent, then
    /// for them to go — sending a first failure nobody answered the question
    /// for as basic. Not on the main thread if the task needs it.
    static func wait(for task: Task<ReportOutcome, Never>? = nil, timeout: TimeInterval = 15) {
        guard isEnabled else { return }
        let deadline = DispatchTime.now() + timeout
        if let task {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await task.value
                done.signal()
            }
            if done.wait(timeout: deadline) == .timedOut {
                logger.warning("Gave up waiting \(Int(timeout))s for a failure report to be ready")
            }
        }
        sendUnansweredAsBasic()
        if sending.wait(timeout: deadline) == .timedOut {
            logger.warning("Gave up waiting \(Int(timeout))s for a failure report to be ready")
        }
        flush()
    }

    /// Wait for queued reports to go, before a process exits on purpose.
    static func flush(timeout: TimeInterval = 3) {
        #if FAILURE_REPORTING
        guard isEnabled else { return }
        SentrySDK.flush(timeout: timeout)
        #endif
    }

    #if FAILURE_REPORTING
    // MARK: The previous run's crash

    /// A crash the SDK found from the previous run (or an uncaught
    /// exception it saved): held back from `beforeSend`, then — on the main
    /// queue, once the process can show an alert and knows where its logs
    /// are — sent again at the detail the setting says, after asking if it
    /// says to ask, or if this is the first failure.
    @MainActor
    private static func previousRunCrashed(_ event: Event) {
        let process = state.withLock { $0.process } ?? .app
        // What CrashMarker logs when it, not Sentry, caught the crash.
        let exception = event.exceptions?.first.map { "\($0.type): \($0.value ?? "")" } ?? "a crash"
        var line = "The previous run crashed (\(exception))"
        if let report = CrashMarker.crashReport(after: event.timestamp?.addingTimeInterval(-60)) {
            line += "\n  Crash report: \(report.path)"
        }
        logger.error("\(line)")
        let preferences = ReportingPreferences.load()
        let detail: ReportDetail?
        if !preferences.promptShown {
            let answer = CrashReportPrompt.askHowDetailed(process: process)
            ReportingPreferences.update {
                $0.level = answer == .detailed ? .detailed : .basic
                $0.promptShown = true
            }
            detail = answer
        } else if let fixed = defaultCrashDetail(for: preferences.level) {
            detail = fixed
        } else {
            detail = CrashReportPrompt.askWhatToSend(process: process)
        }
        guard let detail else {
            logger.notice("Not sending the report of the previous run's crash, as asked")
            return
        }
        let log = detail == .detailed ? previousRunLog(crashedAt: event.timestamp) : nil
        sending.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { sending.leave() }
            resend(event, detail: detail, log: log)
        }
    }

    private static func resend(_ event: Event, detail: ReportDetail, log: URL?) {
        var attachment: Attachment?
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-chance-crash-\(event.eventId.sentryIdString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        if let log {
            do {
                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                let zip = try ReportBundle.make(log: String(decoding: Data(contentsOf: log), as: UTF8.self),
                                                diagnostics: nil, redactor: .current, in: workDirectory)
                attachment = Attachment(path: zip.path, filename: "failure-report.zip", contentType: "application/zip")
            } catch {
                logger.error("Couldn't attach the crashed run's log: \(ErrorChain.describe(error))")
            }
        }
        // On the event itself, not the scope: the SDK applies no scope to
        // an event it read back from a crash (`isFatalEvent`), so a tag set
        // there would never arrive. Scope attachments still go.
        event.tags = (event.tags ?? [:]).merging(["report_detail": detail.rawValue, "crash": "previous-run"]) { $1 }
        SentrySDK.capture(event: event) { scope in
            if let attachment { scope.addAttachment(attachment) }
        }
        logger.notice("Sent a \(detail.rawValue) report of the previous run's crash: \(event.eventId.sentryIdString)")
    }

    /// The log of the run that crashed: the newest run log begun before the
    /// crash (this run's began after it).
    private static func previousRunLog(crashedAt: Date?) -> URL? {
        guard let (directory, prefix) = state.withLock({ $0.runLogs }) else { return nil }
        let keys: [URLResourceKey] = [.creationDateKey]
        let logs = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix + "-") && $0.pathExtension == "log" }
            .compactMap { url -> (URL, Date)? in
                guard let created = (try? url.resourceValues(forKeys: Set(keys)))?.creationDate else { return nil }
                return (url, created)
            }
        let crash = crashedAt ?? Date()
        return logs.filter { $0.1 < crash }.max { $0.1 < $1.1 }?.0
    }

    // MARK: Scrubbing

    /// The last word on what leaves the Mac. Our own reports say their
    /// detail in `report_detail`. Anything without it the SDK made itself —
    /// a crash from the previous run, an uncaught exception — and is held
    /// back for `previousRunCrashed` to send again, tagged.
    private static func scrub(_ event: Event) -> Event? {
        guard let detail = event.tags?["report_detail"].flatMap(ReportDetail.init(rawValue:)) else {
            let id = event.eventId.sentryIdString
            if state.withLock({ $0.heldBack.insert(id).inserted }) {
                DispatchQueue.main.async { previousRunCrashed(event) }
            } else {
                logger.error("Dropped event \(id): it came back to be sent without its report_detail tag")
            }
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
