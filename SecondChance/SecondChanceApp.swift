//
//  SecondChanceApp.swift
//  SecondChance

import SwiftUI
import Logging
import SecondChanceKit
import SecondChanceReporting

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.App")

// Keeps the DispatchSourceSignal handlers alive for the app's lifetime.
// (SwiftUI may discard the App struct after building the view hierarchy.)
private var signalSources: [DispatchSourceSignal] = []

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon, and not brought to the front as it starts (TestHost).
        if TestHost.hidesUI {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nobody to ask in a headless run or under test.
        if !CLIBuilder.isEnabled && !TestHost.isRunning {
            AppMover.offerIfTranslocated()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting part way through installing a game throws the install
        // away: check that's meant. (An update's relaunch waits for the
        // build instead: `AppUpdater`.)
        if WrappBuildHelper.hasTemporaryWrapps, !CLIBuilder.isEnabled, !TestHost.isRunning, !Self.confirmQuitDuringBuild() {
            return .terminateCancel
        }
        // Quitting with the first-failure question unanswered: send the
        // report basic, the error screen saying so, then quit again.
        if FailureReporter.sendUnansweredBeforeQuitting(then: {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }) {
            return .terminateCancel
        }
        logger.notice("🛑 Application terminating, cleaning up...")
        guard !RunningSteam.shared.isEmpty || WrappBuildHelper.hasTemporaryWrapps else {
            finishTerminating()
            return .terminateNow
        }
        // A build may have Steam running — perhaps its sign-in window, left
        // open — or an installer. Stop them before the temporary wrapps they
        // run from are deleted: Steam first, as it keeps Wine going.
        Task { @MainActor in
            if !RunningSteam.shared.isEmpty {
                logger.notice("Stopping the build's Steam before quitting")
                await RunningSteam.shared.stopAll()
            }
            await WrappBuildHelper.endWineInTemporaryWrapps()
            self.finishTerminating()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Whether to quit with a game still being installed.
    private static func confirmQuitDuringBuild() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A game is still being installed"
        alert.informativeText = "If you quit now, installing stops, and you'll need to start again from the beginning."
        alert.addButton(withTitle: "Keep Installing")
        alert.addButton(withTitle: "Quit")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func finishTerminating() {
        WrappBuildHelper.shared.cleanupTemporaryWrapps()
        // A failure report sent from the error screen moments ago.
        FailureReporter.wait(timeout: 10)
        // Drain anything still pending so the disk mirror / stderr don't lose the last lines.
        LogStore.shared.flush()
    }
}

@main
struct SecondChanceApp: App {
    /// The main window's scene id, by which `NSApp.installerWindow` finds it.
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var wrappBuildViewModel: WrappBuildViewModel
    @AppStorage(DebugCommands.settingKey) private var showDebugMenu = false

    private let appStartTime = Date()

    init() {
        // Bootstrap logging before anything else can construct a Logger —
        // a Logger built before this is permanently bound to swift-log's
        // default StreamLogHandler and never reaches LogStore or the window.
        // (Stored-property initialisers that run before init()'s body — e.g.
        // @NSApplicationDelegateAdaptor's AppDelegate — construct no loggers.)
        AppLogging.bootstrap(subsystem: "au.gare.callum.second-chance.SecondChance")
        // `sc screenshot`: draw the catalogued screens and quit, before any window.
        UIStateShots.runIfConfigured(app: "app") { UIStateCatalog.shots }
        MainThreadWatchdog.start()
        // A log per run, for a crash report to carry the run that crashed.
        // Not under test: every test run would push a real run's log out.
        let appLogs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SecondChance/app", isDirectory: true)
        let runLog = TestHost.isRunning ? nil : RotatingLogFile.start(in: appLogs, prefix: "run", logger: logger)
        RunContext.logHeader(logger, extra: [("log", runLog?.path ?? "none")])
        // FailureReporter first: when Sentry handles crashes, CrashMarker
        // installs no handler of its own (docs/failure-reports.md).
        FailureReporter.start(process: .app)
        FailureReporter.setRunLogs(in: appLogs, prefix: "run")
        CrashMarker.install(in: appLogs, logger: logger)
        WrappBuildHelper.shared.sweepStaleTemporaryWrapps()
        LaunchHistory.record()

        // Clear the Wine prefix cache before anything else touches it. Works in
        // both GUI and headless launches (`--clear-wine-cache`).
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

        // The window's view model, which a headless run builds with too.
        let viewModel = WrappBuildViewModel()
        _wrappBuildViewModel = State(initialValue: viewModel)

        if CLIBuilder.isEnabled {
            if !CLIBuilder.showsUI {
                // NSApp may not exist yet during init; defer to first run loop cycle
                DispatchQueue.main.async {
                    NSApp?.setActivationPolicy(.prohibited)
                }
            }
            // Validate synchronously so misconfigured runs fail before the UI
            // starts, then run the build detached so it can drive termination.
            let source = CLIBuilder.validatedSource()
            Task { await CLIBuilder.run(source: source, viewModel: viewModel) }
        }

        Task { await AutomationBridge.shared.startIfConfigured() }

        // Starts the scheduled update checks (off in headless runs).
        _ = AppUpdater.shared

        if debugMode {
            LogWindow.shared.showLogWindow(title: "Installation Log")
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
            WrappBuildHelper.shared.cleanupTemporaryWrapps()
            LogStore.shared.flush()
            exit(130)
        }
        sigintSource.resume()
        signal(SIGINT, SIG_IGN)
        signalSources.append(sigintSource)

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            logger.critical("🛑 Received termination signal, cleaning up...")
            WrappBuildHelper.shared.cleanupTemporaryWrapps()
            LogStore.shared.flush()
            exit(143)
        }
        sigtermSource.resume()
        signal(SIGTERM, SIG_IGN)
        signalSources.append(sigtermSource)
    }

    var body: some Scene {
        // One window, not a group: a second would show the same build, and
        // closing it mid-build would leave the build running out of sight.
        Window("Second Chance", id: Self.mainWindowID) {
            ContentView()
                .environment(wrappBuildViewModel)
        }
        .windowResizability(.contentSize)
        // Under test, each integration-test build has a window of its own
        // (`BuildWindow`), so this one would only show the welcome screen.
        .defaultLaunchBehavior(TestHost.isRunning ? .suppressed : .automatic)
        .restorationBehavior(TestHost.isRunning ? .disabled : .automatic)
        .commands {
            InstallCommands(viewModel: wrappBuildViewModel)
            if DebugCommands.isAlwaysShown || showDebugMenu {
                DebugCommands()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: .shared)
            }
            CommandGroup(after: .appSettings) {
                Button("Sign Out of Steam") { Self.signOutOfSteam() }
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// Forget the Steam sign-in every wrapp shares (docs/steam.md). The next
    /// Steam build, or Steam wrapp, asks for it again.
    private static func signOutOfSteam() {
        let alert = NSAlert()
        do {
            try SteamSessionStore().signOut()
            alert.messageText = "Signed out of Steam"
            alert.informativeText = "Your games will ask you to sign in to Steam again the next time they need it."
        } catch {
            logger.error("Couldn't sign out of Steam: \(error.localizedDescription)")
            alert.messageText = "Couldn't sign out of Steam"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.runModal()
    }
}

/// Whether Second Chance has been opened before, for the welcome screen's
/// greeting. Read and recorded once per launch, so the greeting doesn't
/// change while the window is open.
enum LaunchHistory {
    private static let key = "hasLaunchedBefore"
    private(set) static var isReturning = false

    static func record() {
        // Neither a test nor a headless run is someone opening the app.
        guard !TestHost.isRunning, !CLIBuilder.isEnabled else { return }
        isReturning = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
    }
}
