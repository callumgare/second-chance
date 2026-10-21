//
//  FailureReportModel.swift
//  Shared
//
//  The failure report an error screen is showing, for `FailureReportCallout`:
//  whether it was sent and as what, the Manual choice, the first-failure
//  question, and a comment to add. The build's error screen and a wrapp's
//  error window each own one.

import Foundation
import Combine

@MainActor
final class FailureReportModel: ObservableObject {
    /// The failure on screen, if anything has failed.
    @Published private(set) var report: FailureReport?
    /// What became of it: nil while it is being sent.
    @Published private(set) var outcome: ReportOutcome?
    /// Whether to ask, under the outcome, how detailed reports should be from
    /// now on — the first failure anywhere asks, once.
    @Published private(set) var asksAboutDetail = false
    /// Whether the person sent a comment about this failure.
    @Published private(set) var commentSent = false

    private let preferencesDirectory: URL

    init(preferencesDirectory: URL = ReportingPreferences.defaultDirectory) {
        self.preferencesDirectory = preferencesDirectory
    }

    /// Report a failure at the detail the setting asks for.
    func report(_ report: FailureReport) {
        track(report, sending: Task.detached { await FailureReporter.report(report) })
    }

    /// Show a failure whose report is already under way.
    func track(_ report: FailureReport, sending task: Task<ReportOutcome, Never>) {
        self.report = report
        outcome = nil
        asksAboutDetail = false
        commentSent = false
        Task {
            let outcome = await task.value
            guard self.report?.id == report.id else { return }
            self.show(outcome)
        }
    }

    /// The Manual choice: send at `detail`, or not at all (nil).
    func send(_ detail: ReportDetail?) {
        guard let report else { return }
        guard let detail else {
            outcome = .declined
            return
        }
        outcome = nil
        Task {
            let outcome = await Task.detached { await FailureReporter.send(report, detail: detail) }.value
            guard self.report?.id == report.id else { return }
            self.show(outcome)
        }
    }

    /// The answer to the first-failure question. Detailed also sends a
    /// detailed report of this failure, which so far went as basic.
    func choose(_ level: ReportLevel) {
        ReportingPreferences.update(in: preferencesDirectory) {
            $0.level = level
            $0.promptShown = true
        }
        asksAboutDetail = false
        if level == .detailed, case .sent(_, .basic) = outcome {
            send(.detailed)
        }
    }

    func sendComment(_ text: String, email: String) {
        guard case .sent(let eventID, _) = outcome else { return }
        FailureReporter.sendComment(text, email: email, about: eventID)
        commentSent = true
    }

    func clear() {
        report = nil
        outcome = nil
        asksAboutDetail = false
        commentSent = false
    }

    private func show(_ outcome: ReportOutcome) {
        self.outcome = outcome
        if case .sent = outcome, !ReportingPreferences.load(from: preferencesDirectory).promptShown {
            asksAboutDetail = true
        }
    }

    // MARK: GitHub

    static let newIssueURL = URL(string: "https://github.com/callumgare/second-chance/issues/new")

    /// A new GitHub issue, filled in with what the report says.
    var issueURL: URL? {
        Self.issueURL(report: report, reportID: outcome?.shortID)
    }

    nonisolated static func issueURL(report: FailureReport?, reportID: String?) -> URL? {
        guard let base = newIssueURL, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return newIssueURL
        }
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(x86_64)
        let arch = RunContext.isTranslated ? "Apple silicon (wrapp under Rosetta)" : "Intel"
        #else
        let arch = "Apple silicon"
        #endif
        var details = [
            "- Second Chance: \(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))",
            "- macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)",
        ]
        if let game = report?.game { details.append("- Game: \(game)") }
        if let report { details.append("- What failed: \(report.title)\(report.stage.map { ", while \"\($0)\"" } ?? "")") }
        if let reportID { details.append("- Failure report: \(reportID)") }
        let body = """
            **What happened?**
            <!-- What were you doing when it went wrong? -->


            **Details**
            \(details.joined(separator: "\n"))

            Please attach the log file saved with **Save Logs**.
            """
        components.queryItems = [
            URLQueryItem(name: "title", value: report.map { "\($0.what) failed: \($0.kind)" } ?? ""),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? newIssueURL
    }
}
