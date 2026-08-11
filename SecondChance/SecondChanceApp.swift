//
//  SecondChanceApp.swift
//  SecondChance

import SwiftUI
import os

private let logger = Logger(subsystem: "com.secondchance", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.notice("🛑 Application terminating, cleaning up...")
        GameInstaller.shared.cleanupTemporaryWrappers()
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

        if ProcessInfo.processInfo.environment["NON_INTERACTIVE"] == "true" {
            NSApp.setActivationPolicy(.prohibited)
        }

        Task { await AutomationBridge.shared.startIfConfigured() }

        if debugMode {
            let pid = ProcessInfo.processInfo.processIdentifier
            let startTime = Date()
            LogWindow.shared.showLogWindow(title: "SecondChance - Installation Log")
            LogWindow.shared.startStreaming(pid: pid, since: startTime)
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
