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
import Synchronization

// NOTE: no top-level Logger in main.swift — top-level code here is eager and
// runs in source order, so a logger declared at file scope would be
// constructed before main() can bootstrap the logging system. This file's
// logger lives in MainLogger.swift (lazy global).

/// The error window's explanation when the game has no display a second time.
var noDisplayExplanation: String {
    String(localized: "The game couldn't open its window, because this Mac was too busy while it started. Close some other apps, then open the game again.")
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
        showAlert(message: String(localized: "This Game's App Is Damaged"),
                  informativeText: String(localized: "Something in it is missing. Make the game's app again with Second Chance."))
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "no-executable-path"))
        exit(1)
    }

    let executableURL = URL(fileURLWithPath: executablePath)
    let appPath = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Get bundle ID for prefix path
    guard let bundleId = readPlist(at: WrappLayout(app: appPath).infoPlist, key: "CFBundleIdentifier") else {
        showAlert(message: String(localized: "This Game's App Is Damaged"),
                  informativeText: String(localized: "Something in it is missing. Make the game's app again with Second Chance."))
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
        showAlert(message: String(localized: "This Game's App Is Damaged"),
                  informativeText: String(localized: "Something in it is missing. Make the game's app again with Second Chance."))
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "unreadable-configuration"))
        exit(1)
    }
    let options = WrappLaunchOptions(arguments: CommandLine.arguments)
    let launchingWithoutSteam = options.withoutSteam && loadedConfig.canLaunchWithoutSteam
    let config = launchingWithoutSteam ? loadedConfig.withoutSteam() : loadedConfig

    // The game's files: the exe's folder for Wine, the data folder itself for
    // ScummVM. An install that was cut short shows up here as too small.
    let gamePath = WrappLayout.onDriveC(config.gameExePath, in: config.wine.driveC)
    let gameDir = (try? gamePath.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        ? gamePath : gamePath.deletingLastPathComponent()
    // Every launch keeps its own log, since a wrapp opened from Finder has no
    // terminal to show it. Started before the header; it backfills anyway.
    let gameLogs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SecondChance/\(config.gameSlug)", isDirectory: true)
    let launchLog = RotatingLogFile.start(in: gameLogs, prefix: "launch", logger: mainLogger)
    RunContext.logHeader(mainLogger, extra: [
        ("log", launchLog?.path ?? "none"),
        ("game", "\(config.gameTitle) (\(config.gameSlug)), engine \(config.composition.engineTag)"),
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
    FailureReporter.setGame(config.gameSlug, engine: config.composition.engineTag)
    FailureReporter.setRunLogs(in: gameLogs, prefix: "launch")
    CrashMarker.install(in: gameLogs, logger: mainLogger)

    // Another copy of this game already running (opened with `open -n`, or
    // from a terminal) is the one in use: its Wine is no leftover session
    // for this copy to offer to stop. Bring it forward instead, and go.
    if !options.openedAgain,
       let other = NSRunningApplication.runningApplications(withBundleIdentifier: config.bundleId)
           .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
        mainLogger.notice("\(config.gameTitle) is already running (pid \(other.processIdentifier)): bringing it forward instead")
        other.activate()
        LogStore.shared.flush()
        exit(0)
    }

    // For the whole run: a game that crashes an hour in may have been
    // starved of CPU, too. The loading window observes it, and slows it down
    // once the game has loaded.
    let loadMonitor = SystemLoadMonitor()
    loadMonitor.start()
    if launchingWithoutSteam {
        mainLogger.notice("Starting the game without Steam this time (\(WrappLaunchOptions.withoutSteamArgument)), after a launch through Steam failed")
    }

    let wine = config.wine
    killWineBeforeForcedExit.withLock { $0 = { Blocking.wait { await wine.server.kill() } } }

    var debugMode = options.debugMode
    if options.showsDebugSettings {
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

    // What runs the game: one module for each the composition has.
    guard let modules = RuntimeModules(config: config) else {
        mainLogger.critical("This wrapp can't run \(config.composition) games")
        showAlert(message: String(localized: "This Game's App Is Damaged"),
                  informativeText: String(localized: "Something in it is missing. Make the game's app again with Second Chance."))
        FailureReporter.reportAndWait(FailureReport(what: "Starting the wrapp", kind: "unknown-modules"))
        exit(1)
    }

    // Create game monitor
    let gameMonitor = GameMonitor(config: config, discovery: modules.launcher.findsGame, debugMode: debugMode)

    // Create game launcher
    let gameLauncher = GameLauncher(config: config, gameMonitor: gameMonitor, modules: modules)
    installDiagnosticsSignalHandler(gameLauncher)

    // Set the process name BEFORE initializing NSApplication
    ProcessInfo.processInfo.processName = "Nancy Drew"

    // Initialize NSApplication and set up menu
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)

    // Set up app delegate for cleanup on quit
    let appDelegate = AppDelegate(config: config, gameLauncher: gameLauncher)
    NSApp.delegate = appDelegate

    NSApp.mainMenu = makeMainMenu(appDelegate: appDelegate, config: config, debugMode: debugMode)

    NSApp.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

    // Create log window if in debug mode
    if debugMode {
        LogWindow.shared.showLogWindow(title: "\(config.gameTitle) - Launch Log", relativeTo: nil)

        // Process events to show window
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    // Create info window with game title
    // Show the save warning when a module asks for it (Wine games: ScummVM
    // games are more stable), but not again to someone who saw it moments
    // ago, on the launch through Steam they've given up on.
    let saveWarningEnabled = modules.all.contains { $0.showsSaveWarning } && !launchingWithoutSteam
    // Which processes count as the launch's progress, as the module that
    // can tell says: only this game's Wine, not another game's alongside.
    let isOurs = modules.all.lazy.compactMap(\.ownsProcess).first
    let firstStage = modules.all.lazy.compactMap { $0.firstStage(gameTitle: config.gameTitle) }.first
        ?? .startingGame(title: config.gameTitle)
    let infoWindow = InfoWindowController(
        stage: firstStage,
        appSupportPath: config.appSupportPath, gameSlug: config.gameSlug, gameTitle: config.gameTitle,
        saveWarningEnabled: saveWarningEnabled,
        loadMonitor: loadMonitor,
        activity: LaunchActivityMonitor(
            steamLogsDir: modules.module(SteamRuntime.self)?.logsDir,
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
            if options.afterNoDisplay {
                mainLogger.critical("The game can't show a window (\(line)), again after starting afresh: giving up")
                gameLauncher.reportNoDisplay(final: true)
                infoWindow.showError(exitCode: -1, explanation: noDisplayExplanation,
                                     report: gameLauncher.failureReport, sending: gameLauncher.reportTask)
            } else {
                mainLogger.error("The game can't show a window (\(line)): stopping this launch and starting it afresh")
                gameLauncher.reportNoDisplay(final: false)
                appDelegate.tryAgain = [WrappLaunchOptions.afterNoDisplayArgument]
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

    // Where the player's saves are, as each module's game sees them.
    for module in modules.all {
        do {
            try module.connectSaves(config.appSupportPath)
        } catch {
            showAlert(message: error.title, informativeText: error.detail)
            FailureReporter.reportAndWait(FailureReport(what: error.what, error: error.error,
                                                        game: config.gameSlug, engine: config.composition.engineTag))
            exit(1)
        }
    }

    // The save warning holds back only the game itself: Wine, and Steam for
    // a game that needs it, get going behind it, so the game starts sooner
    // once the player has read it.
    let warningConfirmed = OneTimeSignal()
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

    // Launch based on engine type. On the main actor, as the loading window
    // is: the launch awaits whatever it waits for, so the window keeps going.
    func launchGameAsync() {
        Task {
            await waitForLastSession(wine, infoWindow: infoWindow, then: firstStage)
            let outcome = await gameLauncher.launchGame(infoWindow: infoWindow, debugMode: debugMode) {
                if !warningConfirmed.isSignalled {
                    mainLogger.notice("Ready to start the game; waiting for the player to confirm the save warning")
                    await warningConfirmed.wait()
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
                    await gameLauncher.finishSession()
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
                    await gameLauncher.finishSession()
                    return
                }
            }

            if !debugMode {
                mainLogger.notice("[App Lifecycle] Game ended, exiting cleanly...")
                // From now, opening the game again starts it again once Wine
                // has finished, rather than being ignored while this waits.
                appDelegate.isClosing = true
                await gameLauncher.finishSession()
                // A run can end badly after the game loaded, with no error
                // window: its report still has to go before the wrapp does.
                let reportTask = gameLauncher.reportTask
                await Blocking.run { FailureReporter.wait(for: reportTask, timeout: 120) }
                // The game has gone, but Wine may not have yet.
                await gameLauncher.waitForSessionToEnd()
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

    mainLogger.notice("Launching the game (\(config.composition))...")
    launchGameAsync()

    NSApp.run()
}

// Run the main function
main()
