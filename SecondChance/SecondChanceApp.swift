//
//  SecondChanceApp.swift
//  SecondChance

import SwiftUI
import os

private let logger = Logger(subsystem: "com.secondchance", category: "App")

// Global reference to keep the log stream child process alive for the app's lifetime.
// Can't be stored on the App struct (SwiftUI may discard it) or AppDelegate
// (not yet available during App.init()).
private var logStreamProcess: Process?

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.notice("🛑 Application terminating, cleaning up...")
        GameInstaller.shared.cleanupTemporaryWrappers()
        logStreamProcess?.terminate()
        return .terminateNow
    }
}

@main
struct SecondChanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var installationViewModel = InstallationViewModel()

    private let appStartTime = Date()

    init() {
        let debugMode = CommandLine.arguments.contains("--debug")

        // Stream os.Logger output to stderr when launched from a terminal.
        // Stored in a global so it survives for the app's lifetime (SwiftUI
        // may discard the App struct after building the view hierarchy).
        if isatty(STDERR_FILENO) != 0 {
            let pid = getpid()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            proc.arguments = ["stream", "--process", "\(pid)", "--style", "compact",
                              "--predicate", "subsystem == \"com.secondchance\""]
            proc.standardOutput = FileHandle.standardError
            try? proc.run()
            logStreamProcess = proc
            Thread.sleep(forTimeInterval: 0.3)
        }

        if ProcessInfo.processInfo.environment["NON_INTERACTIVE"] == "true" {
            // NSApp may not exist yet during init; defer to first run loop cycle
            DispatchQueue.main.async {
                NSApp?.setActivationPolicy(.prohibited)
            }
        }

        Task { await AutomationBridge.shared.startIfConfigured() }

        if debugMode {
            LogWindow.shared.showLogWindow(title: "SecondChance - Installation Log")
        }

        setupSignalHandlers()
    }

    private func setupSignalHandlers() {
        signal(SIGINT) { _ in
            logger.fault("🛑 Received interrupt signal, cleaning up...")
            GameInstaller.shared.cleanupTemporaryWrappers()
            exit(130)
        }
        signal(SIGTERM) { _ in
            logger.fault("🛑 Received termination signal, cleaning up...")
            GameInstaller.shared.cleanupTemporaryWrappers()
            exit(143)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(installationViewModel)
                .frame(minWidth: 700, idealWidth: 700, minHeight: 650, idealHeight: 650)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
