//
//  ReportPreviewWindow.swift
//  Shared
//
//  "Show What's Sent…": a window with what a failure report would send, at
//  either level, before the person chooses. Opened from the error screen's
//  report question (`FailureReportCallout`) and from the alert asking about
//  the previous run's crash (`CrashReportPrompt`), where it runs modally.
//  It shows the log, so screenshots for a report leave it out
//  (`WindowScreenshots.mayCapture`).

import AppKit
import Combine
import SecondChanceKit
import SwiftUI

@MainActor
final class ReportPreviewModel: ObservableObject {
    /// Nil while it is being put together.
    @Published var preview: ReportPreview?
}

@MainActor
enum ReportPreviewWindow {

    static let identifier = NSUserInterfaceItemIdentifier("report-preview")

    /// The open windows' delegates, which a window holds only weakly.
    private static var delegates: [ObjectIdentifier: Delegate] = [:]

    /// Open the window at once, and fill it when `make` has put the preview
    /// together (off the main actor).
    static func show(making make: @escaping @Sendable () async -> ReportPreview) {
        let model = ReportPreviewModel()
        let window = window(model: model, modal: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            let preview = await Task.detached { await make() }.value
            guard window.isVisible else {
                preview.removeFiles()
                return
            }
            model.preview = preview
        }
    }

    /// Show `preview` modally, for an alert that is itself modal, and
    /// return once it is closed.
    static func runModal(_ preview: ReportPreview) {
        let model = ReportPreviewModel()
        model.preview = preview
        let window = window(model: model, modal: true)
        window.level = .modalPanel
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    private static func window(model: ReportPreviewModel, modal: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "What's Sent in a Report")
        window.identifier = identifier
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 400)
        window.contentViewController = NSHostingController(rootView: ReportPreviewView(model: model) { [weak window] in
            window?.close()
        })
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        let delegate = Delegate(model: model, modal: modal)
        delegates[ObjectIdentifier(window)] = delegate
        window.delegate = delegate
        return window
    }

    /// Removes the preview's files when its window closes, and ends a modal
    /// run.
    private final class Delegate: NSObject, NSWindowDelegate {
        let model: ReportPreviewModel
        let modal: Bool

        init(model: ReportPreviewModel, modal: Bool) {
            self.model = model
            self.modal = modal
        }

        func windowWillClose(_ notification: Notification) {
            model.preview?.removeFiles()
            if modal { NSApp.stopModal() }
            if let window = notification.object as? NSWindow {
                ReportPreviewWindow.delegates[ObjectIdentifier(window)] = nil
            }
        }
    }
}

struct ReportPreviewView: View {
    @ObservedObject var model: ReportPreviewModel
    let close: () -> Void
    @State private var detail: ReportDetail
    @State private var selectedFile: String?

    init(model: ReportPreviewModel, detail: ReportDetail = .detailed, selectedFile: String? = nil,
         close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _detail = State(initialValue: detail)
        _selectedFile = State(initialValue: selectedFile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Report", selection: $detail) {
                Text("Detailed Report").tag(ReportDetail.detailed)
                Text("Basic Report").tag(ReportDetail.basic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)

            if let preview = model.preview {
                content(preview)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Putting the report together…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("Your name, your Mac's name and your folders are taken out of everything above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(_ preview: ReportPreview) -> some View {
        switch detail {
        case .basic:
            ScrollView {
                fieldsGrid(preview.fields)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .detailed:
            HSplitView {
                List(selection: $selectedFile) {
                    Section("Details") {
                        Text("About the failure").tag(Self.detailsTag)
                    }
                    if !preview.files.isEmpty {
                        Section("Files") {
                            ForEach(preview.files) { file in
                                Text(file.id).tag(file.id)
                            }
                        }
                    }
                }
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

                Group {
                    if let id = selectedFile, let file = preview.files.first(where: { $0.id == id }) {
                        fileView(file)
                    } else {
                        ScrollView {
                            fieldsGrid(preview.fields + preview.detailedFields)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private static let detailsTag = "\u{0}details"

    private func fieldsGrid(_ fields: [ReportPreview.Field]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail == .basic
                 ? "A basic report sends only this:"
                 : "A detailed report sends this, and the files listed beside it:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(fields, id: \.self) { field in
                    GridRow {
                        Text(field.label)
                            .fontWeight(.medium)
                            .gridColumnAlignment(.trailing)
                        Text(field.value)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
        }
        .padding(8)
    }

    @ViewBuilder
    private func fileView(_ file: ReportPreview.File) -> some View {
        switch file.content {
        case .text(let text) where file.id == ReportBundle.logFileName:
            // In the log window's own table, levels tinted and filterable.
            LogFileView(text: text)
                .id(file.id)
        case .text(let text):
            ReadOnlyTextView(text: text)
        case .image(let url):
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 700)
                        .accessibilityLabel(Text("Picture of a window: \(file.id)"))
                }
            }
        }
    }
}

/// A log can run to megabytes, which SwiftUI's `Text` lays out slowly; an
/// `NSTextView` doesn't mind.
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

/// The window filled with made-up values, for `sc screenshot`'s catalogue
/// (`UIStateCatalog`): `detail` showing, and `file` selected if given.
public enum ReportPreviewSample {
    public static let size = CGSize(width: 980, height: 620)

    @MainActor
    public static func view(detail: ReportDetail, file: String? = nil) -> some View {
        let model = ReportPreviewModel()
        model.preview = sample
        return ReportPreviewView(model: model, detail: detail, selectedFile: file) {}
    }

    private static let sample = ReportPreview(
        fields: [
            .init(label: "Second Chance version", value: "1.1.0 (build 412)"),
            .init(label: "macOS version", value: "15.6.1"),
            .init(label: "Mac", value: "Mac14,2, x86_64 under Rosetta"),
            .init(label: "Memory", value: "16 GB"),
            .init(label: "Memory running short", value: "normal"),
            .init(label: "Opened from a temporary copy", value: "No"),
            .init(label: "Where it happened", value: "The game's app"),
            .init(label: "Installation ID", value: "A random number for this copy of Second Chance, not linked to you"),
            .init(label: "What failed", value: "Running the game"),
            .init(label: "How it failed", value: "exit-code"),
            .init(label: "Step", value: "Starting the game"),
            .init(label: "Game", value: "stay-tuned"),
            .init(label: "Installed from", value: "disk"),
            .init(label: "Engine", value: "wine"),
            .init(label: "Exit code", value: "1"),
        ],
        detailedFields: [
            .init(label: "Summary of the failure", value: """
                Running the game failed: the game exited with code 1 after 3.2 s, before its window appeared.
                Game: ~/Applications/Nancy Drew Stay Tuned for Danger.app
                Last Wine error: err:module:import_dll Library MSVCRT.dll not found
                """),
        ],
        files: [
            .init(id: "log.txt", content: .text("""
                2026-11-02T06:02:11.204Z  notice  au.gare.callum.second-chance.WrappTemplate.Launch  ━━━ Nancy Drew Stay Tuned for Danger 1.1.0 (build 412), run 7F3A ━━━
                2026-11-02T06:02:11.391Z  notice  au.gare.callum.second-chance.WrappTemplate.Launch  Game: ~/Applications/Nancy Drew Stay Tuned for Danger.app
                2026-11-02T06:02:11.402Z  notice  au.gare.callum.second-chance.WrappTemplate.WineDesktop  Started Wine's desktop; display devices registered after 0.8 s
                2026-11-02T06:02:12.633Z  notice  au.gare.callum.second-chance.WrappTemplate.Launch  Starting C:\\Program Files\\Nancy Drew\\Stay Tuned for Danger\\STFD.exe
                2026-11-02T06:02:13.112Z  warning  au.gare.callum.second-chance.WrappTemplate.Launch  The Mac is heavily loaded: 7.4 of 8 cores busy
                2026-11-02T06:02:13.870Z  error  au.gare.callum.second-chance.WrappTemplate.Wine  err:module:import_dll Library MSVCRT.dll not found
                2026-11-02T06:02:15.851Z  error  au.gare.callum.second-chance.WrappTemplate.Launch  The game exited with code 1 after 3.2 s, before its window appeared
                2026-11-02T06:02:15.852Z  notice  au.gare.callum.second-chance.WrappTemplate.Reporting  Asking how detailed a failure report to send

                """)),
            .init(id: "screenshots/window-1.png", content: .text("")),
        ]
    )
}
