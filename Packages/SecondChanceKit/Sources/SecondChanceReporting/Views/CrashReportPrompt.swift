//
//  CrashReportPrompt.swift
//  Shared
//
//  What to send of a crash from the previous run, asked as the next run
//  starts: there is no error screen for a crash, so an alert asks instead.
//  `FailureReporter` asks the first time anything fails, and every time
//  when reports are set to ask.

import AppKit
import SecondChanceKit
import SwiftUI

@MainActor
enum CrashReportPrompt {

    /// The first failure: how detailed a report to send, now and later.
    /// `preview` puts together what it would send, for Show What's Sent….
    static func askHowDetailed(process: FailureReporter.Process,
                               preview: @escaping @MainActor () -> ReportPreview) -> ReportDetail {
        let alert = alert(process: process)
        alert.informativeText = "How much should the report include? \(FailureReportCallout.detailedIsWhatHelps)\n\n"
            + "Later reports are sent the same way."
        alert.addButton(withTitle: "Send Detailed Report")
        alert.addButton(withTitle: "Send Basic Report")
        alert.accessoryView = accessory(note: FailureReportCallout.turningOff, preview: preview)
        return alert.runModal() == .alertSecondButtonReturn ? .basic : .detailed
    }

    /// Reports are set to ask: what to send of this crash, or nil for nothing.
    static func askWhatToSend(process: FailureReporter.Process,
                              preview: @escaping @MainActor () -> ReportPreview) -> ReportDetail? {
        let alert = alert(process: process)
        alert.informativeText = "Send a report about it, so it can be fixed? \(FailureReportCallout.levelExplanation)"
        alert.accessoryView = accessory(note: nil, preview: preview)
        alert.addButton(withTitle: "Send Detailed Report")
        alert.addButton(withTitle: "Send Basic Report")
        alert.addButton(withTitle: "Don't Send")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .detailed
        case .alertSecondButtonReturn: return .basic
        default: return nil
        }
    }

    /// Show What's Sent…, and under it `note`, small. The preview opens
    /// over the alert, which waits for it to close.
    private static func accessory(note: String?, preview: @escaping @MainActor () -> ReportPreview) -> NSView {
        let view = NSHostingView(rootView: CrashReportAccessory(note: note) { ReportPreviewWindow.runModal(preview()) })
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        return view
    }

    private static func alert(process: FailureReporter.Process) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = switch process {
        case .app: "Second Chance quit unexpectedly last time"
        case .wrapp: "This game's launcher quit unexpectedly last time"
        }
        // Above a wrapp's loading window, which floats.
        alert.window.level = .modalPanel
        if process == .wrapp {
            // Asked as the wrapp starts, before its menu is up.
            installEditMenuIfNeeded()
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert
    }
}

private struct CrashReportAccessory: View {
    let note: String?
    let showPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Show What's Sent…", action: showPreview)
                .buttonStyle(.link)
                .controlSize(.small)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 260, alignment: .leading)
    }
}
