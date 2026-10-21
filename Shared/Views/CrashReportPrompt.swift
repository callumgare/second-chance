//
//  CrashReportPrompt.swift
//  Shared
//
//  What to send of a crash from the previous run, asked as the next run
//  starts: there is no error screen for a crash, so an alert asks instead.
//  `FailureReporter` asks the first time anything fails, and every time
//  when reports are set to ask.

import AppKit

@MainActor
enum CrashReportPrompt {

    /// The first failure: how detailed reports should be from now on.
    static func askHowDetailed(process: FailureReporter.Process) -> ReportLevel {
        let alert = alert(process: process)
        alert.informativeText = "A report helps get it fixed. \(FailureReportCallout.levelExplanation)\n\nWhich would you like to send, now and when anything fails from now on? You can change this later in Second Chance's Settings."
        alert.addButton(withTitle: "Send Detailed Reports")
        alert.addButton(withTitle: "Send Basic Reports")
        alert.addButton(withTitle: "Ask Each Time")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .detailed
        case .alertThirdButtonReturn: return .manual
        default: return .basic
        }
    }

    /// Reports are set to ask: what to send of this crash, or nil for nothing.
    static func askWhatToSend(process: FailureReporter.Process) -> ReportDetail? {
        let alert = alert(process: process)
        alert.informativeText = "Send a report about it, so it can be fixed? \(FailureReportCallout.levelExplanation)"
        alert.addButton(withTitle: "Send Detailed Report")
        alert.addButton(withTitle: "Send Basic Report")
        alert.addButton(withTitle: "Don't Send")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .detailed
        case .alertSecondButtonReturn: return .basic
        default: return nil
        }
    }

    private static func alert(process: FailureReporter.Process) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = switch process {
        case .app: "Second Chance quit unexpectedly last time"
        case .wrapp: "This game's launcher quit unexpectedly last time"
        }
        // Above a wrapp's loading window, which floats.
        alert.window.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        return alert
    }
}
