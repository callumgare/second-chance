//
//  DebugCommands.swift
//  SecondChance
//
//  The Debug menu: switches for testing and diagnosing builds. It is in
//  every Debug build, and in a Release one launched with ⌥ held.

import AppKit
import SwiftUI

struct DebugCommands: Commands {
    @ObservedObject var settings = DebugSettings.shared
    @ObservedObject var logWindow = LogWindow.shared

    /// Whether this run has the menu, decided once at launch.
    static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return NSEvent.modifierFlags.contains(.option)
        #endif
    }()

    var body: some Commands {
        CommandMenu("Debug") {
            Toggle("Skip Installer", isOn: $settings.skipInstaller)
                .help("Copy the game's files but don't run its installer, for testing a wrapp's set-up without waiting for an install.")

            Divider()

            Toggle("Show Log Window", isOn: Binding(
                get: { logWindow.isVisible },
                set: { show in
                    if show {
                        logWindow.showLogWindow(title: "Installation Log")
                    } else {
                        logWindow.hideLogWindow()
                    }
                }
            ))
            .keyboardShortcut("l", modifiers: [.command, .option])
            // Every entry of this run, where the in-memory log Save Log reads
            // keeps only the last 50,000.
            Button("Show Run Log in Finder") {
                if let log = LogStore.shared.diskMirrorPath {
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                }
            }
            .disabled(LogStore.shared.diskMirrorPath == nil)

            Divider()

            Button("Crash Now…") { confirmCrash() }
            Button("Reset Debug Settings") { settings.resetToDefaults() }
        }
    }

    /// Crash Second Chance on purpose. The next launch should log "The
    /// previous run crashed" and, with failure reports on, send the crash.
    private func confirmCrash() {
        let alert = NSAlert()
        alert.messageText = "Crash Second Chance now?"
        alert.informativeText = "This tests crash reporting. The next launch should say the previous run crashed and, with failure reports on, send the crash."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Crash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            FailureReporter.crashForTesting()
        }
    }
}
