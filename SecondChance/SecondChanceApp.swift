//
//  SecondChanceApp.swift
//  SecondChance
//
//  Created for bringing Nancy Drew games to modern macOS

import SwiftUI

// Application delegate to handle termination events (Cmd+Q)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("\n🛑 Application terminating, cleaning up...")
        GameInstaller.shared.cleanupTemporaryWrappers()
        return .terminateNow
    }
}

@main
struct SecondChanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var installationViewModel = InstallationViewModel()
    
    init() {
        let debugMode = CommandLine.arguments.contains("--debug")

        // In non-interactive mode (subprocess install), suppress all windows and the Dock icon.
        if ProcessInfo.processInfo.environment["NON_INTERACTIVE"] == "true" {
            NSApp.setActivationPolicy(.prohibited)
        }

        // Subscribe LogCorrelator to the bus so step-change headers are emitted.
        Task { await LogCorrelator.shared.subscribe(to: EventBus.app) }

        // Always redirect stdout through LogManager's pipe tee.
        // This ensures print() calls and ContextualLogger output (which emits
        // via print()) are identical in both the console and the log window.
        // LogManager writes to the original console fd AND the log window.
        let logFilePath = ProcessInfo.processInfo.environment["SC_LOG_PATH"]
        LogManager.shared.startRedirectingOutput(toFile: logFilePath)

        // Start the automation bridge if SC_AUTOMATION_SOCKET is set.
        Task { await AutomationBridge.shared.startIfConfigured() }

        // Show the floating log window only in debug mode.
        if debugMode {
            LogManager.shared.showLogWindow(title: "SecondChance - Installation Log")
        }

        // Set up signal handlers for cleanup on exit
        setupSignalHandlers()
    }
    
    /// Set up signal handlers to clean up temporary wrappers on exit
    private func setupSignalHandlers() {
        // Handle SIGINT (Ctrl+C) and SIGTERM
        signal(SIGINT) { _ in
            print("\n🛑 Received interrupt signal, cleaning up...")
            GameInstaller.shared.cleanupTemporaryWrappers()
            exit(130)  // Standard exit code for SIGINT
        }
        
        signal(SIGTERM) { _ in
            print("\n🛑 Received termination signal, cleaning up...")
            GameInstaller.shared.cleanupTemporaryWrappers()
            exit(143)  // Standard exit code for SIGTERM
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
