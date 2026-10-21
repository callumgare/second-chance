//
//  FailureReportModel.swift
//  Shared
//
//  The failure report an error screen is showing, for `FailureReportCallout`:
//  whether it was sent and as what, the first-failure question of how
//  detailed to send it, the Manual choice, and a comment to add. The build's
//  error screen and a wrapp's error window each own one.

import Foundation
import Combine

@MainActor
final class FailureReportModel: ObservableObject {
    /// The failure on screen, if anything has failed.
    @Published private(set) var report: FailureReport?
    /// What became of it: nil while it is being sent.
    @Published private(set) var outcome: ReportOutcome?
    /// Whether the person sent a comment about this failure.
    @Published private(set) var commentSent = false
    /// Set while the report goes basic because the person quit without
    /// answering how detailed to send it.
    @Published private(set) var sendingBeforeQuit = false

    private let preferencesDirectory: URL
    private var quitObserver: AnyCancellable?

    init(preferencesDirectory: URL = ReportingPreferences.defaultDirectory) {
        self.preferencesDirectory = preferencesDirectory
        quitObserver = NotificationCenter.default.publisher(for: FailureReporter.sendingUnansweredOnQuit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let id = note.object as? UUID, self.report?.id == id else { return }
                self.outcome = nil
                self.sendingBeforeQuit = true
            }
    }

    /// Whether the error screen must keep its way out (Quit, Start Over)
    /// back: until the first-failure question is answered, and while the
    /// app is already quitting.
    var holdsBackWayOut: Bool { outcome == .askingHowDetailed || sendingBeforeQuit }

    /// Report a failure at the detail the setting asks for.
    func report(_ report: FailureReport) {
        track(report, sending: Task.detached { await FailureReporter.report(report) })
    }

    /// Show a failure whose report is already under way.
    func track(_ report: FailureReport, sending task: Task<ReportOutcome, Never>) {
        self.report = report
        outcome = nil
        commentSent = false
        Task {
            let outcome = await task.value
            guard self.report?.id == report.id else { return }
            self.outcome = outcome
        }
    }

    /// The Manual choice: send at `detail`, or not at all (nil).
    func send(_ detail: ReportDetail?) {
        guard let report else { return }
        guard let detail else {
            FailureReporter.decline(report)
            outcome = .declined
            return
        }
        outcome = nil
        let sending = FailureReporter.sendInBackground(report, detail: detail)
        Task {
            let outcome = await sending.value
            guard self.report?.id == report.id else { return }
            self.outcome = outcome
        }
    }

    /// The answer to the first-failure question: send this report at
    /// `detail`, and send later ones the same way.
    func choose(_ detail: ReportDetail) {
        ReportingPreferences.update(in: preferencesDirectory) {
            $0.level = detail == .detailed ? .detailed : .basic
            $0.promptShown = true
        }
        send(detail)
    }

    func sendComment(_ text: String, email: String) {
        guard case .sent(let eventID, _) = outcome else { return }
        FailureReporter.sendComment(text, email: email, about: eventID)
        commentSent = true
    }

    func clear() {
        report = nil
        outcome = nil
        commentSent = false
        sendingBeforeQuit = false
    }
}
