//
//  SecondChanceApp.swift
//  SecondChance

import SwiftUI
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.App")

// Keeps the DispatchSourceSignal handlers alive for the app's lifetime.
// (SwiftUI may discard the App struct after building the view hierarchy.)
private var signalSources: [DispatchSourceSignal] = []

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.notice("🛑 Application terminating, cleaning up...")
        GameInstaller.shared.cleanupTemporaryWrappers()
        // Drain anything still pending so the disk mirror / stderr don't lose the last lines.
        LogStore.shared.flush()
        return .terminateNow
    }
}

@main
struct SecondChanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var installationViewModel = InstallationViewModel()

    private let appStartTime = Date()

    init() {
        // Bootstrap logging before anything else can construct a Logger —
        // a Logger built before this is permanently bound to swift-log's
        // default StreamLogHandler and never reaches LogStore or the window.
        // (Stored-property initialisers that run before init()'s body — e.g.
        // @NSApplicationDelegateAdaptor's AppDelegate — construct no loggers.)
        AppLogging.bootstrap(subsystem: "au.gare.callum.second-chance.SecondChance")

        // Clear the Wine prefix cache before anything else touches it. Works in
        // both GUI and headless launches (run.sh --clear-wine-cache).
        if CommandLine.arguments.contains("--clear-wine-cache") {
            logger.notice("Clearing Wine prefix cache...")
            do {
                try WineManager.shared.clearCache()
            } catch {
                logger.critical("Failed to clear Wine prefix cache: \(error.localizedDescription)")
                LogStore.shared.flush()
                exit(1)
            }
        }

        let debugMode = CommandLine.arguments.contains("--debug")

        if CLIBuilder.isEnabled {
            // NSApp may not exist yet during init; defer to first run loop cycle
            DispatchQueue.main.async {
                NSApp?.setActivationPolicy(.prohibited)
            }
            // Validate synchronously so misconfigured runs fail before the UI
            // starts, then run the build detached so it can drive termination.
            let source = CLIBuilder.validatedSource()
            Task { await CLIBuilder.run(source: source) }
        }

        Task { await AutomationBridge.shared.startIfConfigured() }

        if debugMode {
            LogWindow.shared.showLogWindow(title: "SecondChance - Installation Log")
        }

        setupSignalHandlers()
    }

    private func setupSignalHandlers() {
        // DispatchSourceSignal delivers on the main queue where normal logging
        // is safe. A raw signal() handler must not touch LogStore — the mutex
        // is not async-signal-safe and would deadlock if the signal lands on a
        // thread already holding the store's lock.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            logger.critical("🛑 Received interrupt signal, cleaning up...")
            GameInstaller.shared.cleanupTemporaryWrappers()
            LogStore.shared.flush()
            exit(130)
        }
        sigintSource.resume()
        signal(SIGINT, SIG_IGN)
        signalSources.append(sigintSource)

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            logger.critical("🛑 Received termination signal, cleaning up...")
            GameInstaller.shared.cleanupTemporaryWrappers()
            LogStore.shared.flush()
            exit(143)
        }
        sigtermSource.resume()
        signal(SIGTERM, SIG_IGN)
        signalSources.append(sigtermSource)
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
