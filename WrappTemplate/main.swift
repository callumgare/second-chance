//
//  main.swift
//  WrappTemplate
//
//  Main entry point for Nancy Drew game wrappers

import Foundation
import AppKit
import Logging
import os
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

// NOTE: no top-level Logger in main.swift — top-level code here is eager and
// runs in source order, so a logger declared at file scope would be
// constructed before main() can bootstrap the logging system. This file's
// logger lives in MainLogger.swift (lazy global).

// MARK: - Debug Settings

func showDebugSettings(_ config: GameConfig, initialDebugMode: Bool) -> (shouldContinue: Bool, debugMode: Bool) {
    // Initialize NSApplication if not already done
    _ = NSApplication.shared
    installEditMenuIfNeeded()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Process events briefly to allow activation to complete
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    // Keep showing dialog until user chooses to continue or cancel
    while true {
        let alert = NSAlert()
        alert.messageText = "Debug Settings"
        let debugStatus = initialDebugMode ? "Enabled" : "Disabled"
        alert.informativeText = "Game: \(config.appPath.lastPathComponent)\nEngine: \(config.gameEngine.rawValue)\nPrefix: \(config.winePrefix.path)\n\n"
            + "Launch Command: \(getGameLaunchInfo(config).formatLaunchCommand())\n\nDebug Mode: \(debugStatus)"
        alert.alertStyle = .informational

        // Add checkbox for debug mode
        let debugCheckbox = NSButton(checkboxWithTitle: "Enable Debug Mode (show log window)", target: nil, action: nil)
        debugCheckbox.state = initialDebugMode ? .on : .off
        alert.accessoryView = debugCheckbox

        alert.addButton(withTitle: "Continue Launch")
        alert.addButton(withTitle: "Open Debug Shell")
        alert.addButton(withTitle: "Wine Control Panel")
        alert.addButton(withTitle: "Wine Config")
        alert.addButton(withTitle: "Show Wine Prefix in Finder")
        alert.addButton(withTitle: "Crash Now (test crash reporting)")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let debugModeEnabled = debugCheckbox.state == .on

        switch response {
        case .alertFirstButtonReturn:  // Continue Launch
            return (true, debugModeEnabled)
        case .alertSecondButtonReturn:  // Open Debug Shell
            launchShell(config)
        case .alertThirdButtonReturn:  // Wine Control Panel
            launchWineControlPanel(config)
        case NSApplication.ModalResponse(rawValue: 1003):  // Wine Config
            launchWineConfig(config)
        case NSApplication.ModalResponse(rawValue: 1004):  // Show Wine Prefix in Finder
            showWinePrefixInFinder(config)
        case NSApplication.ModalResponse(rawValue: 1005):  // Crash Now
            FailureReporter.crashForTesting()
        default:  // Cancel
            return (false, debugModeEnabled)
        }
    }
}

func launchWineShell(_ config: GameConfig) {
    mainLogger.notice("Opening Wine shell...")

    let wine = config.wine

    mainLogger.notice("Wine prefix: \(config.winePrefix)")
    mainLogger.notice("Wine environment variables: \(wine.variables)")

    // Get the game launch command
    let launchInfo = getGameLaunchInfo(config)
    let gameLaunchCommand = launchInfo.formatLaunchCommand()

    // Build shell script using process substitution for init file (to work around SIP stripping DYLD_* variables)
    // Note: they'll still be stripped when you call system binaries like "env" from within the shell but other binaries
    // should inherit them.
    var script = "#!/bin/bash\n"
    script += "exec /bin/bash --init-file <(cat <<'INIT_EOF'\n"

    // Welcome message
    script += "clear\n"
    script += "echo 'Wine Debug Shell'\n"
    script += "echo '================'\n"
    script += "echo 'Wine environment variables have been set.'\n"
    script += "echo ''\n"
    script += "echo 'Game launch command:'\n"
    // Properly escape single quotes in the game launch command for display
    let escapedCommand = gameLaunchCommand.replacingOccurrences(of: "'", with: "'\\''")
    script += "echo '  \(escapedCommand)'\n"
    script += "echo ''\n"
    script += "echo 'Useful commands:'\n"
    script += "echo '  wine --version'\n"
    script += "echo '  wineserver -k                                    (kill all Wine processes)'\n"
    script += "echo '  \"$(which wineserver)\" -f -p                      (start the wineserver - for some reason this fails unless path is absolute)'\n"
    script += "echo '  wine winecfg                                          (Wine configuration)'\n"
    script += "echo '  wine \"C:\\windows\\syswow64\\cnc-ddraw config.exe\"  (cnc-ddraw configuration)'\n"
    script += "echo ''\n"

    // Export all Wine environment variables; Wine's binaries come first on
    // their PATH.
    script += wine.shellExports + "\n"
    script += "echo 'Wine binaries are now in PATH'\n"

    // CD to drive_c directory
    let driveCPath = wine.driveC.path
    let escapedDriveCPath = driveCPath.replacingOccurrences(of: "'", with: "'\\''")
    script += "cd '\(escapedDriveCPath)'\n"
    script += "echo 'Current directory: '\n"
    script += "pwd\n"
    script += "echo ''\n"

    script += "INIT_EOF\n"
    script += ")\n"

    // Write script to temporary .command file
    let tempCommand = FileManager.default.temporaryDirectory.appendingPathComponent("debug-shell-\(UUID().uuidString).command")

    do {
        try script.write(to: tempCommand, atomically: true, encoding: .utf8)

        // Make it executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempCommand.path)

        // Open the .command file (macOS will open it in Terminal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [tempCommand.path]
        try process.run()

        mainLogger.notice("Debug shell opened in Terminal")
    } catch {
        mainLogger.error("Error creating shell command file: \(error)")
    }
}

func launchScummvmShell(_ config: GameConfig) {
    mainLogger.notice("Opening ScummVM shell...")

    // Get the game launch info
    let launchInfo = getGameLaunchInfo(config)
    let gameLaunchCommand = launchInfo.formatLaunchCommand()

    // Build shell script
    var script = "#!/bin/bash\n"
    script += "exec /bin/bash --init-file <(cat <<'INIT_EOF'\n"

    // Welcome message
    script += "clear\n"
    script += "echo 'ScummVM Debug Shell'\n"
    script += "echo '==================='\n"
    script += "echo 'ScummVM binary: \(launchInfo.executable)'\n"
    script += "echo ''\n"
    script += "echo 'Arguments:'\n"
    for arg in launchInfo.arguments {
        let escapedArg = arg.replacingOccurrences(of: "'", with: "'\\''")
        script += "echo '  \(escapedArg)'\n"
    }
    script += "echo ''\n"

    script += "echo 'Game launch command:'\n"
    let escapedCommand = gameLaunchCommand.replacingOccurrences(of: "'", with: "'\\''")
    script += "echo '  \(escapedCommand)'\n"
    script += "echo ''\n"
    script += "echo 'Useful commands:'\n"
    script += "echo '  \"\(launchInfo.executable)\" --help'\n"
    script += "echo '  \"\(launchInfo.executable)\" --list-games'\n"
    script += "echo ''\n"

    // CD to directory containing the binary (if there's a working directory, use that)
    let targetDir = launchInfo.workingDirectory ?? (launchInfo.executable as NSString).deletingLastPathComponent
    let escapedTargetDir = targetDir.replacingOccurrences(of: "'", with: "'\\''")
    script += "cd '\(escapedTargetDir)'\n"
    script += "echo 'Current directory: '\n"
    script += "pwd\n"
    script += "echo ''\n"

    script += "INIT_EOF\n"
    script += ")\n"

    // Write script to temporary .command file
    let tempCommand = FileManager.default.temporaryDirectory.appendingPathComponent("debug-shell-\(UUID().uuidString).command")

    do {
        try script.write(to: tempCommand, atomically: true, encoding: .utf8)

        // Make it executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempCommand.path)

        // Open the .command file (macOS will open it in Terminal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [tempCommand.path]
        try process.run()

        mainLogger.notice("Debug shell opened in Terminal")
    } catch {
        mainLogger.error("Error creating shell command file: \(error)")
    }
}

func launchShell(_ config: GameConfig) {
    switch config.gameEngine {
    case .scummvm:
        launchScummvmShell(config)
    case .wine, .wineSteam, .wineSteamSilent:
        launchWineShell(config)
    }
}

func launchWineControlPanel(_ config: GameConfig) {
    mainLogger.notice("Launching Wine control panel...")
    runInTerminal(.wine(["control"]), with: config.wine)
}

func launchWineConfig(_ config: GameConfig) {
    mainLogger.notice("Launching Wine config...")
    // winecfg is a Windows program, run through wine: Wine has no bin/winecfg.
    runInTerminal(.wine(["winecfg"]), with: config.wine)
}

/// Run `command` with our own stdin, stdout and stderr, and wait for it:
/// its exit code, or 1 when it couldn't be run or was killed.
@discardableResult
func runInTerminal(_ command: WineCommand, with wine: Wine) -> Int32 {
    do {
        try Blocking.wait { try await wine.run(command, output: .terminal) }
        return 0
    } catch WineError.executionFailed(let code) {
        return code
    } catch {
        mainLogger.error("Couldn't run \(command.displayName): \(error)")
        return 1
    }
}

func showWinePrefixInFinder(_ config: GameConfig) {
    mainLogger.notice("Opening Wine prefix in Finder: \(config.winePrefix.path)")
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: config.winePrefix.path)
}

// MARK: - Debug Menu Handler

class DebugMenuHandler: NSObject {
    let config: GameConfig

    init(config: GameConfig) {
        self.config = config
        super.init()
    }

    @objc func openDebugShell() {
        launchShell(config)
    }
}

// MARK: - Application Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app menu's Failure Reports…: what the shared settings are, and
    /// that Second Chance is where they change.
    @objc func showFailureReportSettings() {
        let preferences = ReportingPreferences.load()
        let level = preferences.level
        let alert = NSAlert()
        alert.messageText = "Failure Reports"
        let current: String
        switch level {
        case .detailed: current = "When the game fails to start, a detailed report is sent, with the log (your name and folders taken out)."
        case .basic: current = "When the game fails to start, a basic report is sent: which game, and what failed."
        case .manual: current = "When the game fails to start, you're asked what to send."
        }
        let success = preferences.successReports == true
            ? "Success reports are on: Second Chance counts when a game starts, and whether it worked."
            : "Success reports are off."
        alert.informativeText = "\(current)\n\n\(success)\n\nYou can change these in Second Chance → Settings. They apply to all your games."
        alert.runModal()
    }

    let config: GameConfig
    let gameLauncher: GameLauncher?
    var isCleaningUp = false
    /// Set when the game crashes during loading, so quitting propagates the game's exit code.
    var gameExitCode: Int32 = 0
    /// Set when the player chose "Start Without Steam": once this launch is
    /// cleaned up, the wrapp opens again with `--launch-without-steam`.
    var relaunchWithoutSteam = false
    /// The player chose Try Again on a launch that seemed stuck, or the game
    /// had no display driver: once Wine has finished, a fresh copy starts,
    /// with these arguments.
    var tryAgain: [String]?
    /// The game has ended and the wrapp is closing down: waiting for Wine,
    /// hidden from the Dock. Set from the game's thread, read on main.
    private let closingState = OSAllocatedUnfairLock(initialState: (closing: false, openAgain: false))
    var isClosing: Bool {
        get { closingState.withLock { $0.closing } }
        set { closingState.withLock { $0.closing = newValue } }
    }
    /// Someone opened the game again while it was closing down: once Wine
    /// has finished, a fresh copy starts.
    var openAgainWhenClosed: Bool { closingState.withLock { $0.openAgain } }

    init(config: GameConfig, gameLauncher: GameLauncher?) {
        self.config = config
        self.gameLauncher = gameLauncher
        super.init()
    }

    /// Chosen in Cmd-Tab while the game runs: the game is in a process of
    /// its own, so the wrapp passes it on. Not while one of the
    /// wrapp's own windows is up (the log window, in debug mode), which the
    /// person may have clicked to get to.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isCleaningUp, !isClosing, !NSApp.windows.contains(where: { $0.isVisible }) else { return }
        _ = gameLauncher?.bringGameForward()
    }

    /// While the game runs, clicking the wrapp in the Dock brings the game,
    /// which runs in a process of its own, forward.
    ///
    /// Opening the game while this copy is closing down reaches this copy
    /// (macOS reactivates a running app rather than starting another), which
    /// would do nothing. Remember it, and start again once Wine has finished.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isCleaningUp || isClosing else {
            guard gameLauncher?.hasGameWindow == true else { return true }
            // A click in the Dock sends the reopen before the wrapp is made
            // active, and only an active app can hand activation on: then
            // applicationDidBecomeActive, which follows, does it.
            if NSApp.isActive { _ = gameLauncher?.bringGameForward() }
            return false
        }
        mainLogger.notice("Opened again while the game is closing: it starts again once Wine has finished")
        closingState.withLock { $0.openAgain = true }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainLogger.debug("[Cleanup/AppDelegate] applicationShouldTerminate called")

        // Quitting a launch that seems stuck: report it, then quit again.
        // Not on the way to relaunching without Steam, which isn't giving up.
        // Nor when the game had no display driver, already reported.
        if !isCleaningUp, !relaunchWithoutSteam, tryAgain != [afterNoDisplayArgument],
           globalInfoWindow?.giveUpIfStuck() == true {
            mainLogger.notice("Quitting while the launch seems stuck: reporting it before quitting")
            return .terminateCancel
        }

        // Quitting with the first-failure question unanswered: send the
        // report basic, the error window saying so, then quit again.
        if !isCleaningUp, FailureReporter.sendUnansweredBeforeQuitting(then: {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }) {
            return .terminateCancel
        }

        // Prevent multiple cleanup attempts
        guard !isCleaningUp else {
            mainLogger.debug("[Cleanup/AppDelegate] Already cleaning up, returning .terminateNow")
            return .terminateNow
        }

        mainLogger.debug("[Cleanup/AppDelegate] Setting isCleaningUp = true")
        isCleaningUp = true

        guard let gameLauncher = gameLauncher else {
            mainLogger.debug("[Cleanup/AppDelegate] No gameLauncher, returning .terminateNow")
            return .terminateNow
        }

        mainLogger.notice("[Cleanup/AppDelegate] Application terminating, performing cleanup...")

        // Perform cleanup and wait for completion
        mainLogger.debug("[Cleanup/AppDelegate] About to call gameLauncher.performCleanup...")
        gameLauncher.performCleanup {
            mainLogger.debug("[Cleanup/AppDelegate] Inside performCleanup completion handler")
            // Quitting from the error window: let its report finish going.
            FailureReporter.wait(for: gameLauncher.reportTask, timeout: 10)
            DispatchQueue.main.async {
                mainLogger.debug("[Cleanup/AppDelegate] On main queue, about to call NSApp.reply")
                mainLogger.notice("[Cleanup] All cleanup complete, terminating application")
                // Drain pending entries so the disk mirror / stderr keep the last lines.
                if self.relaunchWithoutSteam {
                    self.openAgain(arguments: [launchWithoutSteamArgument], why: "to start without Steam")
                } else if let arguments = self.tryAgain {
                    self.openAgain(arguments: arguments, why: "to try the launch again")
                } else if self.openAgainWhenClosed {
                    self.openAgain(arguments: [], why: "as it was opened while closing")
                }
                LogStore.shared.flush()
                if self.gameExitCode != 0 {
                    exit(self.gameExitCode)
                }
                NSApp.reply(toApplicationShouldTerminate: true)
                mainLogger.debug("[Cleanup/AppDelegate] NSApp.reply(toApplicationShouldTerminate: true) called")
            }
        }

        mainLogger.debug("[Cleanup/AppDelegate] Returning .terminateLater")
        // Return later - we'll call reply when cleanup is done
        return .terminateLater
    }

    /// Open a new instance of this wrapp, with `arguments`. Called once Steam
    /// and the Wine session have been stopped, so the new instance finds the
    /// prefix free. Through `open`, so it outlives us.
    func openAgain(arguments wrappArguments: [String], why: String) {
        var arguments = ["-n", config.appPath.path, "--args"] + wrappArguments
        if CommandLine.arguments.contains("--debug") { arguments.append("--debug") }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        do {
            try open.run()
            open.waitUntilExit()
            if open.terminationStatus == 0 {
                mainLogger.notice("[Cleanup] Opened \(config.gameTitle) again, \(why)")
            } else {
                mainLogger.error("[Cleanup] Couldn't open \(config.gameTitle) again (\(why)): open exited \(open.terminationStatus)")
            }
        } catch {
            mainLogger.error("[Cleanup] Couldn't open \(config.gameTitle) again (\(why)): \(error.localizedDescription)")
        }
    }
}

/// Starts a DRM-free game the user chose to launch through Steam directly
/// instead, for this launch only. Passed by the wrapp to itself when the
/// player picks "Start Without Steam" after a launch through Steam failed.
let launchWithoutSteamArgument = "--launch-without-steam"
/// Passed to the copy started afresh after the game had no display driver,
/// so that a second time shows the error rather than starting it again.
let afterNoDisplayArgument = "--after-no-display"
/// The error window's explanation when it happens again.
let noDisplayExplanation = "The game couldn't open its window, because this Mac was too busy while it started. Close some other apps, then open the game again."

// MARK: - Termination signals

/// Kept alive for the life of the process.
private var terminationSignalSources: [DispatchSourceSignal] = []

/// Keeps App Nap off for the life of the process (`main`).
private var appNapOff: NSObjectProtocol?

/// Kills the game's Wine session, once the configuration is known: called
/// when the wrapp has to exit without its cleanup having finished.
private var killWineBeforeForcedExit: (() -> Void)?

/// Capture a diagnostics bundle on SIGUSR1, whatever the launch or the game
/// is doing: `kill -USR1 <wrapp pid>`, for a game that seems stuck. See
/// `StartupDiagnostics`.
private func installDiagnosticsSignalHandler(_ gameLauncher: GameLauncher) {
    var set = sigset_t()
    sigemptyset(&set)
    sigaddset(&set, SIGUSR1)
    pthread_sigmask(SIG_UNBLOCK, &set, nil)
    signal(SIGUSR1, SIG_IGN)
    // Not on the main queue, which may be what is stuck.
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .userInitiated))
    source.setEventHandler {
        mainLogger.notice("Received SIGUSR1: capturing diagnostics")
        gameLauncher.captureDiagnostics(.manual)
    }
    source.resume()
    terminationSignalSources.append(source)
}

/// Quit like Cmd-Q on SIGTERM, SIGINT or SIGHUP: end the game and its Wine
/// session and log that it happened, instead of dying silently or (when the
/// signal arrived masked) not at all.
private func installTerminationHandlers() {
    // A signal blocked by whoever started us stays blocked across exec;
    // unblock these so they are delivered at all.
    var set = sigset_t()
    sigemptyset(&set)
    for sig in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&set, sig) }
    pthread_sigmask(SIG_UNBLOCK, &set, nil)

    for (sig, code) in [(SIGTERM, Int32(143)), (SIGINT, 130), (SIGHUP, 129)] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            mainLogger.notice("Received \(SubprocessWatch.signalName(sig)): quitting the game")
            // Off the main queue, so it fires even if the main thread is stuck;
            // later on a busy Mac, whose quit gets longer (`quitPeriods`).
            DispatchQueue.global(qos: .userInitiated).async {
                let after = GameLauncher.quitPeriods(announce: false).forcedExitAfter
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + after) {
                    mainLogger.error("Cleanup didn't finish within \(Int(after)) s of \(SubprocessWatch.signalName(sig)); exiting anyway")
                    // Not with Wine still running in the prefix, though.
                    killWineBeforeForcedExit?()
                    LogStore.shared.flush()
                    exit(code)
                }
            }
            // Not called here: this handler is a block on the main queue, and
            // terminate (via .terminateLater) waits in a nested event loop for
            // the cleanup's reply, which is itself queued on the main queue —
            // behind this block. A wrapp quit while Steam waited for a
            // sign-in hung there for good. From the run loop, the main queue
            // keeps draining while terminate waits.
            RunLoop.main.perform(inModes: [.common]) {
                NSApplication.shared.terminate(nil)
            }
        }
        source.resume()
        terminationSignalSources.append(source)
    }
}

// MARK: - The last session

/// Wine still running in the prefix is usually the game's last session, its
/// wrapp still waiting for it to close down, which takes seconds. Wait for it
/// in the loading window (`.lastSessionClosing`), which after a few seconds
/// also offers to stop it; if it closes before anyone answers, the offer goes
/// and the launch carries on to `nextStage`. Runs off the main thread, before
/// the game starts; "Quit" exits the wrapp, leaving it be.
private func waitForLastSession(_ wine: Wine, infoWindow: InfoWindowController, then nextStage: LoadingStage) {
    let server = wine.server
    // Programs a killed session left behind never finish, and the game among
    // them would be taken for this launch's (`WineServer.clearLeftovers`).
    Blocking.wait { await server.clearLeftovers() }
    guard Blocking.wait({ await server.isRunning }) else { return }
    mainLogger.notice("Wine is still running in this game's prefix, probably from the last time it was played: waiting for it to finish")
    let started = Date()
    infoWindow.setStage(.lastSessionClosing)

    enum Outcome { case ended, choice(InfoWindowViewModel.LastSessionChoice) }
    let decided = DispatchSemaphore(value: 0)
    let outcome = OSAllocatedUnfairLock<Outcome?>(initialState: nil)
    let decide: @Sendable (Outcome) -> Void = { value in
        let first = outcome.withLock { current -> Bool in
            guard current == nil else { return false }
            current = value
            return true
        }
        if first { decided.signal() }
    }
    let waiter = server.onStop { decide(.ended) }
    DispatchQueue.main.async {
        infoWindow.onLastSessionChoice = { choice in decide(.choice(choice)) }
    }
    if waiter == nil, !Blocking.wait({ await server.isRunning }) { decide(.ended) }
    decided.wait()
    waiter?.terminate()
    DispatchQueue.main.async { infoWindow.onLastSessionChoice = nil }

    let waited = SubprocessWatch.duration(Date().timeIntervalSince(started))
    switch outcome.withLock({ $0 }) {
    case .ended, nil:
        mainLogger.notice("The last session's Wine finished after \(waited)")
    case .choice(.stopItAndContinue):
        mainLogger.notice("Player chose to stop the last session's Wine after \(waited)")
        let stopped = Blocking.wait {
            await server.stop()
            return await server.waitUntilStopped(timeout: 10)
        }
        if !stopped {
            mainLogger.warning("The last session's Wine was still running 10 s after it was stopped; starting anyway")
        }
    case .choice(.continueAnyway):
        mainLogger.notice("Player chose to start with the last session's Wine still running, after \(waited)")
    case .choice(.dontStart):
        mainLogger.notice("Player chose not to start the game while the last session's Wine is running")
        LogStore.shared.flush()
        exit(0)
    }
    infoWindow.setStage(nextStage)
}

// MARK: - Main

func main() {
    // Bootstrap logging before anything else can construct a Logger.
    AppLogging.bootstrap(subsystem: "au.gare.callum.second-chance.WrappTemplate")
    // `sc screenshot`: draw the catalogued windows and quit, before any window.
    UIStateShots.runIfConfigured(app: "wrapp") { UIStateCatalog.shots }
    // Before anything can fail. CrashMarker after it: when Sentry handles
    // crashes, CrashMarker installs no handler of its own.
    FailureReporter.start(process: .wrapp)
    CrashMarker.arm()
    installTerminationHandlers()
    // The wrapp is in the background behind the game for as long as it
    // runs, where macOS naps it within a minute: every thread down to
    // priority 4, which on a Mac with every core busy never gets the CPU.
    // It then can't see the game end, quit when asked, or end Wine, until
    // the load goes. It sleeps, as the game does, when the Mac does.
    appNapOff = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching over the game while it runs")
    // Before any Wine process starts, so that every one inherits them.
    for (name, value) in Wine.wrappSessionVariables() {
        setenv(name, value, 1)
    }

    // Get app path for prefix determination
    guard let executablePath = ProcessInfo.processInfo.arguments.first else {
        showAlert(message: "This Game's App Is Damaged", informativeText: "Something in it is missing. Make the game's app again with Second Chance.")
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "no-executable-path"))
        exit(1)
    }

    let executableURL = URL(fileURLWithPath: executablePath)
    let appPath = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Get bundle ID for prefix path
    guard let bundleId = readPlist(at: WrappLayout(app: appPath).infoPlist, key: "CFBundleIdentifier") else {
        showAlert(message: "This Game's App Is Damaged", informativeText: "Something in it is missing. Make the game's app again with Second Chance.")
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "no-bundle-identifier"))
        exit(1)
    }

    // Determine wine prefix (will use cache if read-only)
    let winePrefix = getWinePrefix(appPath: appPath, bundleId: bundleId)

    // `wine` subcommand: when the bundle binary is invoked directly from a
    // terminal, act as a thin pass-through to the bundled Wine binary for this
    // game's prefix, then exit with Wine's status. Stdio is inherited, so output
    // streams to the calling terminal. Examples:
    //   /path/Game.app/Contents/MacOS/WrappTemplate wine --version
    //   /path/Game.app/Contents/MacOS/WrappTemplate wine '\start' explorer.exe
    // Returns `nil` for normal launches (double-click, `open`, `--debug`, …),
    // so the regular game-launch flow below is unchanged.
    if let wineArgs = extractWineSubcommand(from: CommandLine.arguments) {
        exit(runInTerminal(.wine(wineArgs), with: Wine(wrapp: appPath, prefix: winePrefix)))
    }

    // Load configuration
    guard let loadedConfig = loadConfig(customWinePrefix: winePrefix) else {
        showAlert(message: "This Game's App Is Damaged", informativeText: "Something in it is missing. Make the game's app again with Second Chance.")
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "unreadable-configuration"))
        exit(1)
    }
    let launchingWithoutSteam = CommandLine.arguments.contains(launchWithoutSteamArgument)
        && loadedConfig.canLaunchWithoutSteam
    let config = launchingWithoutSteam ? loadedConfig.withoutSteam() : loadedConfig

    // The game's files: the exe's folder for Wine, the data folder itself for
    // ScummVM. An install that was cut short shows up here as too small.
    let gamePath = WrappLayout.onDriveC(config.gameExePath, in: config.wine.driveC)
    let gameDir = config.gameEngine == .scummvm ? gamePath : gamePath.deletingLastPathComponent()
    // Every launch keeps its own log, since a wrapp opened from Finder has no
    // terminal to show it. Started before the header; it backfills anyway.
    let gameLogs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SecondChance/\(config.gameSlug)", isDirectory: true)
    let launchLog = RotatingLogFile.start(in: gameLogs, prefix: "launch", logger: mainLogger)
    RunContext.logHeader(mainLogger, extra: [
        ("log", launchLog?.path ?? "none"),
        ("game", "\(config.gameTitle) (\(config.gameSlug)), engine \(config.gameEngine.rawValue)"),
        ("game files", gameDir.path),
        ("game exe", config.gameExePath),
        ("app", config.appPath.path),
        ("prefix", config.winePrefix.path),
        ("saves", config.appSupportPath.path),
    ])
    // How big the game's files are says whether an install was cut short,
    // but walking them takes seconds on a cold disk: not before the window.
    DispatchQueue.global(qos: .utility).async {
        mainLogger.notice("Game files: \(DirectorySize.measure(gameDir).description) in \(gameDir.path)")
    }
    FailureReporter.setGame(config.gameSlug, engine: config.gameEngine.rawValue)
    FailureReporter.setRunLogs(in: gameLogs, prefix: "launch")
    CrashMarker.install(in: gameLogs, logger: mainLogger)
    // For the whole run: a game that crashes an hour in may have been
    // starved of CPU, too. The loading window observes it, and slows it down
    // once the game has loaded.
    let loadMonitor = SystemLoadMonitor()
    loadMonitor.start()
    if launchingWithoutSteam {
        mainLogger.notice("Starting the game without Steam this time (\(launchWithoutSteamArgument)), after a launch through Steam failed")
    }

    let wine = config.wine
    killWineBeforeForcedExit = { Blocking.wait { await wine.server.kill() } }

    // Check for debug mode
    var debugMode = false
    var shouldShowDebugSettings = false

    for arg in CommandLine.arguments {
        if arg == "--debug" {
            debugMode = true
            mainLogger.notice("--debug flag detected - debug mode enabled")
        } else if arg == "--debug-options" {
            shouldShowDebugSettings = true
        }
    }

    // Show debug settings if requested
    if shouldShowDebugSettings {
        if debugMode {
            mainLogger.notice("--debug and --debug-options flags detected - showing debug settings with debug mode pre-enabled")
        } else {
            mainLogger.notice("--debug-options flag detected - showing debug settings")
        }
        let (shouldContinue, debugModeFromDialog) = showDebugSettings(config, initialDebugMode: debugMode)
        debugMode = debugModeFromDialog
        if !shouldContinue {
            mainLogger.notice("Launch cancelled from debug settings")
            exit(0)
        }
    }

    if debugMode {
        mainLogger.notice("Debug mode enabled - log window will be shown")
    }

    // Create game monitor
    let gameMonitor = GameMonitor(config: config, debugMode: debugMode)

    // Create game launcher
    let gameLauncher = GameLauncher(config: config, gameMonitor: gameMonitor)
    installDiagnosticsSignalHandler(gameLauncher)

    // Set the process name BEFORE initializing NSApplication
    ProcessInfo.processInfo.processName = "Nancy Drew"

    // Initialize NSApplication and set up menu
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)

    // Set up app delegate for cleanup on quit
    let appDelegate = AppDelegate(config: config, gameLauncher: gameLauncher)
    NSApp.delegate = appDelegate

    let mainMenu = NSMenu()

    // App menu
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu(title: "Nancy Drew")
    appMenuItem.submenu = appMenu

    let reportsItem = NSMenuItem(
        title: "Failure Reports…",
        action: #selector(AppDelegate.showFailureReportSettings),
        keyEquivalent: ""
    )
    reportsItem.target = appDelegate
    appMenu.addItem(reportsItem)
    appMenu.addItem(.separator())

    let quitItem = NSMenuItem(
        title: "Quit",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenu.addItem(quitItem)

    mainMenu.addItem(makeEditMenuItem())

    // Debug menu (only in debug mode)
    if debugMode {
        let debugMenuItem = NSMenuItem()
        mainMenu.addItem(debugMenuItem)
        let debugMenu = NSMenu(title: "Debug")
        debugMenuItem.submenu = debugMenu

        // Create a menu handler to capture config
        let menuHandler = DebugMenuHandler(config: config)

        let openShellItem = NSMenuItem(
            title: "Open Debug Shell",
            action: #selector(DebugMenuHandler.openDebugShell),
            keyEquivalent: ""
        )
        openShellItem.target = menuHandler
        debugMenu.addItem(openShellItem)

        // Keep the handler alive
        objc_setAssociatedObject(NSApp!, "debugMenuHandler", menuHandler, .OBJC_ASSOCIATION_RETAIN)
    }

    NSApp.mainMenu = mainMenu

    NSApp.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

    // Create log window if in debug mode
    if debugMode {
        LogWindow.shared.showLogWindow(title: "\(config.gameTitle) - Launch Log", relativeTo: nil)

        // Process events to show window
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    // Create info window with game title
    // Only show save warning for Wine games (ScummVM games are more stable),
    // and not again to someone who saw it moments ago, on the launch through
    // Steam they've given up on.
    let saveWarningEnabled = config.gameEngine.runsInWine && !launchingWithoutSteam
    // Only this game's Wine counts as its launch's progress: another game's,
    // running alongside, would keep a stuck launch looking busy. ScummVM
    // works in no prefix.
    let server = config.wine.server
    var isOurs: (@Sendable (pid_t) -> Bool)?
    if config.gameEngine.runsInWine {
        isOurs = { pid in !server.isElsewhere(pid) }
    }
    let infoWindow = InfoWindowController(
        stage: config.gameEngine.needsSteam ? .startingSteam : .startingGame(title: config.gameTitle),
        appSupportPath: config.appSupportPath, gameSlug: config.gameSlug, gameTitle: config.gameTitle,
        saveWarningEnabled: saveWarningEnabled,
        loadMonitor: loadMonitor,
        activity: LaunchActivityMonitor(
            steamLogsDir: config.gameEngine.needsSteam
                ? config.winePrefix.appendingPathComponent(SteamClient.steamDirInPrefix).appendingPathComponent("logs") : nil,
            isOurs: isOurs))
    globalInfoWindow = infoWindow
    PuppetServer.startIfRequested()
    infoWindow.reportStuckLaunch = { gameLauncher.reportStuckLaunch() }
    infoWindow.reportStuckLaunchWithoutQuitting = { gameLauncher.reportStuckLaunchWithoutQuitting() }
    infoWindow.onTryAgain = {
        // Quitting reports the launch as stuck, if it hasn't been already,
        // and opens the game again once Wine has finished.
        mainLogger.notice("Player chose to try the launch again: stopping this launch, then opening the game again")
        appDelegate.tryAgain = []
        NSApp.terminate(nil)
    }
    // The game's Wine has no display driver: it can never show a window.
    // The Mac was too busy as it started (cocoa_start_wait.m), which a fresh
    // start usually gets past; a second time, say so.
    gameLauncher.onNoDisplay = { line in
        DispatchQueue.main.async {
            guard appDelegate.tryAgain == nil else { return }
            if CommandLine.arguments.contains(afterNoDisplayArgument) {
                mainLogger.critical("The game can't show a window (\(line)), again after starting afresh: giving up")
                gameLauncher.reportNoDisplay(final: true)
                infoWindow.showError(exitCode: -1, explanation: noDisplayExplanation,
                                     report: gameLauncher.failureReport, sending: gameLauncher.reportTask)
            } else {
                mainLogger.error("The game can't show a window (\(line)): stopping this launch and starting it afresh")
                gameLauncher.reportNoDisplay(final: false)
                appDelegate.tryAgain = [afterNoDisplayArgument]
                NSApp.terminate(nil)
            }
        }
    }
    infoWindow.onPossibleFailure = { gameLauncher.captureDiagnostics(.stalled) }
    gameLauncher.onQuitStep = { step in infoWindow.quitting(step) }
    if config.canLaunchWithoutSteam {
        infoWindow.onLaunchWithoutSteam = {
            mainLogger.notice("Player chose to launch without Steam: stopping this launch, then opening the wrapp again")
            appDelegate.relaunchWithoutSteam = true
            NSApp.terminate(nil)
        }
    }

    if debugMode {
        // If log window exists in debug mode, reposition it relative to info window
        if let logWindow = LogWindow.shared.window {
            // Reposition relative to info window
            let referenceFrame = infoWindow.window!.frame
            let newOrigin = NSPoint(
                x: referenceFrame.maxX + 10,
                y: referenceFrame.origin.y
            )
            logWindow.setFrameOrigin(newOrigin)
        }
    }

    infoWindow.show()

    // Process events to show window
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

    mainLogger.notice("Starting game...")

    // Setup Wine environment (only for Wine games)
    if config.gameEngine.runsInWine {
        do {
            try config.wine.drives.mount(config.appSupportPath, as: "a")
        } catch {
            mainLogger.critical("ERROR: Failed to mount directory into Wine: \(error)")
            showAlert(message: "Couldn't Open Your Saved Games",
                      informativeText: "The game couldn't reach the folder where your saved games are kept: \(error.localizedDescription)")
            FailureReporter.reportAndWait(FailureReport(what: "Mounting the saves folder", error: error,
                                                        game: config.gameSlug, engine: config.gameEngine.rawValue))
            exit(1)
        }

        // Link save directory
        let documentsPath = config.wine.documents
        do {
            var targetPath: URL? = documentsPath

            // Check if documentsPath exists (including broken symlinks)
            mainLogger.debug("Checking if Documents directory exists at: \(documentsPath.path)")

            // Check for symlink existence (works even if target doesn't exist)
            let attributes = try? FileManager.default.attributesOfItem(atPath: documentsPath.path)
            mainLogger.debug("Attributes: \(String(describing: attributes))")
            let itemExists = attributes != nil

            if itemExists {
                mainLogger.debug("Documents directory exists at: \(documentsPath.path)")
            } else {
                mainLogger.debug("Documents directory does not exist at: \(documentsPath.path)")
            }

            // A real folder, not the link this makes, may hold saves the game
            // wrote there: move it aside, never delete it.
            if itemExists, attributes?[.type] as? FileAttributeType == .typeDirectory {
                let aside = documentsPath.deletingLastPathComponent()
                    .appendingPathComponent("Documents (kept \(Int(Date().timeIntervalSince1970)))")
                mainLogger.warning("Documents in the prefix is a folder, not a link to the saves: moving it to \(aside.lastPathComponent)")
                try FileManager.default.moveItem(at: documentsPath, to: aside)
            } else if itemExists {
                do {
                    // Replace the link
                    try FileManager.default.removeItem(at: documentsPath)
                } catch {
                    // Check if it's a permission error
                    mainLogger.critical("ERROR: \(error)")
                    mainLogger.notice("Unable to remove Documents so treating as as a symlink...")

                    // Check if it's a symlink and get where it points
                    do {
                        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: documentsPath.path)
                        mainLogger.notice("Documents is a symlink pointing to: \(destination)")

                        // Convert destination to absolute URL
                        if destination.hasPrefix("/") {
                            targetPath = URL(fileURLWithPath: destination)
                        } else {
                            // It's a relative path, resolve it relative to documentsPath's parent
                            targetPath = documentsPath.deletingLastPathComponent().appendingPathComponent(destination).standardized
                        }

                        // If targetPath exists, set it to nil
                        if let resolvedPath = targetPath, FileManager.default.fileExists(atPath: resolvedPath.path) {
                            mainLogger.notice("Target path already exists, skipping")
                            targetPath = nil
                        } else if let resolvedPath = targetPath {
                            mainLogger.notice("Will create new symlink at: \(resolvedPath.path)")
                        }
                    } catch {
                        mainLogger.critical("ERROR: Could not read symlink destination: \(error)")
                        throw error
                    }
                }
            }

            if let targetPath = targetPath {
                try FileManager.default.createSymbolicLink(at: targetPath, withDestinationURL: config.appSupportPath)
            }
        } catch {
            mainLogger.critical("ERROR: Failed to create symbolic link for Documents directory: \(error)")
            showAlert(message: "Couldn't Open Your Saved Games",
                      informativeText: "The game couldn't reach the folder where your saved games are kept: \(error.localizedDescription)")
            FailureReporter.reportAndWait(FailureReport(what: "Linking the saves folder", error: error,
                                                        game: config.gameSlug, engine: config.gameEngine.rawValue))
            exit(1)
        }
    }

    // Record game engine on first run
    let gameEngineFile = config.appSupportPath.appendingPathComponent("game-engine")
    if !FileManager.default.fileExists(atPath: gameEngineFile.path) {
        try? config.gameEngine.rawValue.write(to: gameEngineFile, atomically: true, encoding: .utf8)
    }

    // The save warning holds back only the game itself: Wine, and Steam for
    // a game that needs it, get going behind it, so the game starts sooner
    // once the player has read it.
    let warningConfirmed = DispatchSemaphore(value: 0)
    if infoWindow.isShowingWarning {
        mainLogger.notice("Showing the save warning; getting Wine ready behind it")
        infoWindow.onWarningConfirmed = {
            mainLogger.notice("Warning confirmed")
            warningConfirmed.signal()
        }
    } else {
        mainLogger.notice("No warning to show")
        warningConfirmed.signal()
    }

    // Launch based on engine type
    func launchGameAsync() {
        DispatchQueue.global(qos: .userInitiated).async {
            waitForLastSession(wine, infoWindow: infoWindow, then: config.gameEngine.needsSteam
                ? .startingSteam : .startingGame(title: config.gameTitle))
            let outcome = gameLauncher.launchGame(infoWindow: infoWindow, debugMode: debugMode) {
                if warningConfirmed.wait(timeout: .now()) == .timedOut {
                    mainLogger.notice("Ready to start the game; waiting for the player to confirm the save warning")
                    warningConfirmed.wait()
                }
                mainLogger.notice("Launching the game")
            }

            // Quitting: the app delegate's cleanup stopped the game, waits for
            // Wine and ends the wrapp. Showing an error or exiting here would
            // cut that short.
            if gameLauncher.isQuitting { return }

            switch outcome {
            case .notStarted, .failedAndTold:
                // Nothing more to show: the player chose this, or was told.
                break
            case .ended(let exitCode, let failed, let windowAppeared):
                // A game that quit before it had started, or just after Wine
                // reported an error, failed whatever its exit code says.
                if let failure = gameLauncher.unexpectedQuit {
                    appDelegate.gameExitCode = exitCode != 0 ? exitCode : 1
                    infoWindow.showError(exitCode: exitCode, explanation: failure.explanation,
                                         report: gameLauncher.failureReport, sending: gameLauncher.reportTask)
                    gameLauncher.finishSession()
                    return
                }
                // One that ended badly before its window appeared: the player
                // saw nothing of it, so say so. (Wine games often exit non-zero
                // from a normal quit; that is judged in `handleGameTermination`.)
                if failed && !windowAppeared {
                    mainLogger.error("The game ended before its window appeared (exit \(exitCode))")
                    appDelegate.gameExitCode = exitCode != 0 ? exitCode : 1
                    infoWindow.showError(exitCode: exitCode,
                                         report: gameLauncher.failureReport, sending: gameLauncher.reportTask)
                    gameLauncher.finishSession()
                    return
                }
            }

            if !debugMode {
                mainLogger.notice("[App Lifecycle] Game ended, exiting cleanly...")
                // From now, opening the game again starts it again once Wine
                // has finished, rather than being ignored while this waits.
                appDelegate.isClosing = true
                gameLauncher.finishSession()
                // A run can end badly after the game loaded, with no error
                // window: its report still has to go before the wrapp does.
                FailureReporter.wait(for: gameLauncher.reportTask, timeout: 120)
                // The game has gone, but Wine may not have yet.
                gameLauncher.waitForWineToEnd()
                if appDelegate.openAgainWhenClosed {
                    appDelegate.openAgain(arguments: [], why: "as it was opened while closing")
                }
                // Or the launch log loses its last lines, the game's exit among them.
                LogStore.shared.flush()
                exit(0)
            } else {
                mainLogger.notice("[Debug Mode] Game ended. Wrapper staying open. Press Cmd+Q to quit.")
            }
        }
    }

    switch config.gameEngine {
    case .wine:
        launchGameAsync()

    case .wineSteam, .wineSteamSilent:
        mainLogger.notice("Launching through Steam...")
        launchGameAsync()

    case .scummvm:
        mainLogger.notice("Launching ScummVM game...")
        launchGameAsync()
    }

    NSApp.run()
}

// Run the main function
main()
