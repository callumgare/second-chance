//
//  main.swift
//  WrappTemplate
//
//  Main entry point for Nancy Drew game wrappers

import Foundation
import AppKit
import Logging
import os

// NOTE: no top-level Logger in main.swift — top-level code here is eager and
// runs in source order, so a logger declared at file scope would be
// constructed before main() can bootstrap the logging system. This file's
// logger lives in MainLogger.swift (lazy global).

// MARK: - Debug Settings

func showDebugSettings(_ config: GameConfig, initialDebugMode: Bool) -> (shouldContinue: Bool, debugMode: Bool) {
    // Initialize NSApplication if not already done
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Process events briefly to allow activation to complete
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    // Keep showing dialog until user chooses to continue or cancel
    while true {
        let alert = NSAlert()
        alert.messageText = "Debug Settings"
        let debugStatus = initialDebugMode ? "Enabled" : "Disabled"
        alert.informativeText = "Game: \(config.appPath.lastPathComponent)\nEngine: \(config.gameEngine)\nPrefix: \(config.winePrefix.path)\n\n"
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

    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    let wineEnvVars = wine.wineSpecificEnvironmentVariables()

    mainLogger.notice("Wine prefix: \(config.winePrefix)")
    mainLogger.notice("Wine environment variables: \(wineEnvVars)")

    let wineBinPath = config.appPath.path + "/Contents/SharedSupport/wine/bin"

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
    script += "echo 'Wine binary directory: \(wineBinPath)'\n"
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

    // Export all Wine environment variables
    for (key, value) in wineEnvVars.sorted(by: { $0.key < $1.key }) {
        let escapedValue = value.replacingOccurrences(of: "'", with: "'\\''")
        script += "export \(key)='\(escapedValue)'\n"
    }

    // Add wine bin directory to the front of PATH
    let escapedWineBinPath = wineBinPath.replacingOccurrences(of: "'", with: "'\\''")
    script += "export PATH='\(escapedWineBinPath)':$PATH\n"
    script += "echo 'Wine binaries are now in PATH'\n"

    // CD to drive_c directory
    let driveCPath = config.winePrefix.path + "/drive_c"
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
    case "scummvm":
        launchScummvmShell(config)
        // launchWineShell(config)
    case "wine", "wine-steam", "wine-steam-silent":
        launchWineShell(config)
    default:
        mainLogger.warning("Warning: Unknown game engine \(config.gameEngine), attempting Wine shell")
        launchWineShell(config)
    }
}

func launchWineControlPanel(_ config: GameConfig) {
    mainLogger.notice("Launching Wine control panel...")
    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    wine.runExecutable("wine", arguments: ["control"])
}

func launchWineConfig(_ config: GameConfig) {
    mainLogger.notice("Launching Wine config...")
    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    wine.runExecutable("winecfg")
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
    /// The app menu's Failure Reports…: what the shared setting is, and that
    /// Second Chance is where it changes.
    @objc func showFailureReportSettings() {
        let level = ReportingPreferences.load().level
        let alert = NSAlert()
        alert.messageText = "Failure Reports"
        let current: String
        switch level {
        case .detailed: current = "When the game fails to start, a detailed report is sent, with the log (your name and folders taken out)."
        case .basic: current = "When the game fails to start, a basic report is sent: which game, and what failed."
        case .manual: current = "When the game fails to start, you're asked what to send."
        }
        alert.informativeText = "\(current)\n\nYou can change this in Second Chance → Settings. It applies to all your games."
        alert.runModal()
    }

    let config: GameConfig
    let gameLauncher: GameLauncher?
    var isCleaningUp = false
    /// Set when the game crashes during loading, so quitting propagates the game's exit code.
    var gameExitCode: Int32 = 0
    /// Set when the player chose "Launch Directly": once this launch is
    /// cleaned up, the wrapp opens again with `--launch-without-steam`.
    var relaunchWithoutSteam = false
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

    /// Opening the game while this copy is closing down reaches this copy
    /// (macOS reactivates a running app rather than starting another), which
    /// would do nothing. Remember it, and start again once Wine has finished.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard isCleaningUp || isClosing else { return true }
        mainLogger.notice("Opened again while the game is closing: it starts again once Wine has finished")
        closingState.withLock { $0.openAgain = true }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainLogger.debug("[Cleanup/AppDelegate] applicationShouldTerminate called")

        // Quitting a launch that seems stuck: report it, then quit again.
        // Not on the way to relaunching without Steam, which isn't giving up.
        if !isCleaningUp, !relaunchWithoutSteam, globalInfoWindow?.giveUpIfStuck() == true {
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
/// player picks "Launch Directly" after a launch through Steam failed.
let launchWithoutSteamArgument = "--launch-without-steam"

// MARK: - Termination signals

/// Kept alive for the life of the process.
private var terminationSignalSources: [DispatchSourceSignal] = []

/// Kills the game's Wine session, once the configuration is known: called
/// when the wrapp has to exit without its cleanup having finished.
private var killWineBeforeForcedExit: (() -> Void)?

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
            // Off the main queue, so it fires even if the main thread is stuck.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                mainLogger.error("Cleanup didn't finish within 15 s of \(SubprocessWatch.signalName(sig)); exiting anyway")
                // Not with Wine still running in the prefix, though.
                killWineBeforeForcedExit?()
                LogStore.shared.flush()
                exit(code)
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
/// the game starts; "Don't Start the Game" exits the wrapp, leaving it be.
private func waitForLastSession(_ wine: WineEnvironment, infoWindow: InfoWindowController, then nextStage: LoadingStage) {
    guard wine.isWineserverRunning() else { return }
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
    let waiter = WineUtilities.onSessionEnd(wine) { decide(.ended) }
    DispatchQueue.main.async {
        infoWindow.onLastSessionChoice = { choice in decide(.choice(choice)) }
    }
    if waiter == nil, !wine.isWineserverRunning() { decide(.ended) }
    decided.wait()
    waiter?.terminate()
    DispatchQueue.main.async { infoWindow.onLastSessionChoice = nil }

    let waited = SubprocessWatch.duration(Date().timeIntervalSince(started))
    switch outcome.withLock({ $0 }) {
    case .ended, nil:
        mainLogger.notice("The last session's Wine finished after \(waited)")
    case .choice(.stopItAndContinue):
        mainLogger.notice("Player chose to stop the last session's Wine after \(waited)")
        wine.stopWineserver()
        if !WineUtilities.waitForSessionEnd(wine, timeout: 10) {
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
    // Before anything can fail. CrashMarker after it: when Sentry handles
    // crashes, CrashMarker installs no handler of its own.
    FailureReporter.start(process: .wrapp)
    CrashMarker.arm()
    installTerminationHandlers()
    // Before any Wine process starts, so that every one inherits them.
    for (name, value) in WineEnvironment.wrappSessionVariables() {
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
    let infoPlistPath = appPath.appendingPathComponent("Contents/Info.plist")

    // Get bundle ID for prefix path
    guard let bundleId = readPlist(at: infoPlistPath, key: "CFBundleIdentifier") else {
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
        let wine = WineEnvironment(appPath: appPath, customPrefixDir: winePrefix)
        let exitCode = wine.runExecutable("wine", arguments: wineArgs)
        exit(exitCode)
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
    let driveC = config.winePrefix.appendingPathComponent("drive_c")
    let gamePath = driveC.appendingPathComponent(String(config.gameExePath.drop(while: { $0 == "/" })))
    let gameDir = config.gameEngine == "scummvm" ? gamePath : gamePath.deletingLastPathComponent()
    // Every launch keeps its own log, since a wrapp opened from Finder has no
    // terminal to show it. Started before the header; it backfills anyway.
    let gameLogs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SecondChance/\(config.gameSlug)", isDirectory: true)
    let launchLog = RotatingLogFile.start(in: gameLogs, prefix: "launch", logger: mainLogger)
    RunContext.logHeader(mainLogger, extra: [
        ("log", launchLog?.path ?? "none"),
        ("game", "\(config.gameTitle) (\(config.gameSlug)), engine \(config.gameEngine)"),
        ("game files", "\(DirectorySize.measure(gameDir).description) in \(gameDir.path)"),
        ("game exe", config.gameExePath),
        ("app", config.appPath.path),
        ("prefix", config.winePrefix.path),
        ("saves", config.appSupportPath.path),
    ])
    FailureReporter.setGame(config.gameSlug, engine: config.gameEngine)
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

    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    killWineBeforeForcedExit = { WineUtilities.killSession(wine) }

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

    // Edit menu
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenuItem.submenu = editMenu

    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

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
    let saveWarningEnabled = (config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-")) && !launchingWithoutSteam
    let infoWindow = InfoWindowController(
        stage: config.gameEngine.hasPrefix("wine-steam") ? .startingSteam : .startingGame(title: config.gameTitle),
        appSupportPath: config.appSupportPath, gameSlug: config.gameSlug, gameTitle: config.gameTitle,
        saveWarningEnabled: saveWarningEnabled,
        loadMonitor: loadMonitor,
        activity: LaunchActivityMonitor(steamLogsDir: config.gameEngine.hasPrefix("wine-steam")
            ? config.winePrefix.appendingPathComponent(SteamClient.steamDirInPrefix).appendingPathComponent("logs") : nil))
    globalInfoWindow = infoWindow
    PuppetServer.startIfRequested()
    infoWindow.reportStuckLaunch = { gameLauncher.reportStuckLaunch() }
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
    if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-steam") {
        do {
            try mountDirectoryIntoWine(config, hostPath: config.appSupportPath, driveLetter: "a")
        } catch {
            mainLogger.critical("ERROR: Failed to mount directory into Wine: \(error)")
            showAlert(message: "Couldn't Open Your Saved Games",
                      informativeText: "The game couldn't reach the folder where your saved games are kept: \(error.localizedDescription)")
            FailureReporter.reportAndWait(FailureReport(what: "Mounting the saves folder", error: error,
                                                        game: config.gameSlug, engine: config.gameEngine))
            exit(1)
        }

        // Link save directory
        let documentsPath = config.winePrefix.appendingPathComponent("drive_c/users/\(WineEnvironment.wineUsername)/Documents")
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

            if itemExists {
                do {
                    // Try to remove it
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
                                                        game: config.gameSlug, engine: config.gameEngine))
            exit(1)
        }
    }

    // Record game engine on first run
    let gameEngineFile = config.appSupportPath.appendingPathComponent("game-engine")
    if !FileManager.default.fileExists(atPath: gameEngineFile.path) {
        try? config.gameEngine.write(to: gameEngineFile, atomically: true, encoding: .utf8)
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
            waitForLastSession(wine, infoWindow: infoWindow, then: config.gameEngine.hasPrefix("wine-steam")
                ? .startingSteam : .startingGame(title: config.gameTitle))
            let exitCode = gameLauncher.launchGame(infoWindow: infoWindow, debugMode: debugMode) {
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

            // A game that quit before it had started, or just after Wine
            // reported an error, failed whatever its exit code says.
            if let failure = gameLauncher.unexpectedQuit {
                appDelegate.gameExitCode = exitCode != 0 ? exitCode : 1
                infoWindow.showError(exitCode: exitCode, explanation: failure.explanation,
                                     report: gameLauncher.failureReport, sending: gameLauncher.reportTask)
                return
            }

            // Only treat non-zero exit as an error if the game never loaded.
            // Wine games often exit with non-zero codes during normal quit.
            if exitCode != 0 && !infoWindow.hasGameLoaded {
                mainLogger.error("Game exited with non-zero status: \(exitCode)")
                appDelegate.gameExitCode = exitCode
                infoWindow.showError(exitCode: exitCode,
                                     report: gameLauncher.failureReport, sending: gameLauncher.reportTask)
                return
            }

            if !debugMode {
                mainLogger.notice("[App Lifecycle] Game ended, exiting cleanly...")
                // A run can end badly after the game loaded, with no error
                // window: its report still has to go before the wrapp does.
                FailureReporter.wait(for: gameLauncher.reportTask, timeout: 120)
                // The game has gone, but Wine may not have yet.
                appDelegate.isClosing = true
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
    case "wine":
        launchGameAsync()

    case "wine-steam", "wine-steam-silent":
        mainLogger.notice("Launching through Steam...")
        launchGameAsync()

    case "scummvm":
        mainLogger.notice("Launching ScummVM game...")
        launchGameAsync()

    default:
        mainLogger.critical("ERROR: Unknown game engine: \(config.gameEngine)")
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "unknown-engine",
                                                    game: config.gameSlug, engine: config.gameEngine))
        exit(1)
    }

    NSApp.run()
}

// Run the main function
main()
