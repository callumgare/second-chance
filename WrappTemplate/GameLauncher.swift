//
//  GameLauncher.swift
//  WrappTemplate
//
//  Game launching logic for Nancy Drew game wrappers

import Foundation
import AppKit
import Logging

// MARK: - Directory Mounting

func mountDirectoryIntoWine(_ config: GameConfig, hostPath: URL, driveLetter: String) throws {
    let dosdevicesPath = config.winePrefix.appendingPathComponent("dosdevices")
    let linkPath = dosdevicesPath.appendingPathComponent("\(driveLetter):")
    
    try? FileManager.default.createDirectory(at: dosdevicesPath, withIntermediateDirectories: true)
    
    // Remove existing link if present
    try? FileManager.default.removeItem(at: linkPath)
    
    // Create symlink
    try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: hostPath)
}

// MARK: - Game Launch Info

struct GameLaunchInfo {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let gameExeName: String?
    let gameExePath: String?  // Unix path to the game executable (for Wine games)
    
    func formatLaunchCommand() -> String {
        let formattedCommand = formatShellCommand(executable: executable, arguments: arguments)
        if let workingDir = workingDirectory {
            return "cd \(shellQuote(workingDir)) && \(formattedCommand)"
        }
        return formattedCommand
    }
}

func getGameLaunchInfo(_ config: GameConfig) -> GameLaunchInfo {
    // Wine game launch info
    let gameExePathClean = config.gameExePath.hasPrefix("/")
        ? String(config.gameExePath.dropFirst())
        : config.gameExePath
    
    let gameExeUnixPath = config.winePrefix
        .appendingPathComponent("drive_c")
        .appendingPathComponent(gameExePathClean)
        .path
    
    let gameInstallerDirUnixPath = config.winePrefix
        .appendingPathComponent("drive_c")
        .appendingPathComponent(config.gameInstallerDir)
        .path
    
    let gameExeName = (gameExeUnixPath as NSString).lastPathComponent
    let gameExeDir = (gameExeUnixPath as NSString).deletingLastPathComponent
    switch config.gameEngine {
    case "wine":
        fallthrough
    case _ where config.gameEngine.hasPrefix("wine-"):
        let wineBinaryPath = config.appPath.path + "/Contents/SharedSupport/wine/bin/wine"
        
        return GameLaunchInfo(
            executable: wineBinaryPath,
            arguments: ["start", "/wait", gameExeName],
            workingDirectory: gameExeDir,
            gameExeName: gameExeName,
            gameExePath: gameExeUnixPath
        )
        
    case "scummvm":
        // ScummVM game launch info
        let resourcesPath = config.appPath.appendingPathComponent("Contents/Resources")
        let scummvmBinary = config.appPath.appendingPathComponent("Contents/MacOS/scummvm").path
        let scummvmIni = resourcesPath.appendingPathComponent("scummvm.ini").path
        let savePath = config.appSupportPath.path
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(config.bundleId).ini").path
        
        let arguments = [
            "-f",                           // Fullscreen
            "--config=\(configPath)",       // User config file location
            "--initial-cfg=\(scummvmIni)",  // Configuration template to copy into configPath if there's no existing config
            "--path=\(gameInstallerDirUnixPath)",           // Game files location
            "--savepath=\(savePath)",       // Save files location
            "--auto-detect"                 // Automatically detect and start game
        ]
        
        return GameLaunchInfo(
            executable: scummvmBinary,
            arguments: arguments,
            workingDirectory: nil,
            gameExeName: nil,  // ScummVM doesn't have a separate game exe
            gameExePath: nil
        )
        
    default:
        fatalError("Unknown game engine: \(config.gameEngine)")
    }
}

// MARK: - Game Launcher

class GameLauncher {
    private let config: GameConfig
    private let gameMonitor: GameMonitor
    private var currentProcess: Process?
    private var cleanupCompleted = false
    /// Captures a diagnostics bundle if a Wine game starts badly; nil for ScummVM.
    private var diagnostics: StartupDiagnostics?
    /// The desktop `prepareDesktop` started, if it did. See `releaseDesktop`.
    private var desktop: WineDesktop?
    /// Steam, for a game that needs it running (`wine-steam*`).
    private var steam: WrappSteam?
    /// What the in-process helpers report from inside the game; Wine games only.
    private var helperReport: InProcessHelperReport?
    /// Judges whether a Wine game's exit was a quit; nil for ScummVM.
    private var quitCheck: GameQuitCheck?
    /// Set when the game's exit was no quit, but the game failing: it quit
    /// before it had started, or just after Wine reported an error.
    private(set) var unexpectedQuit: GameQuitCheck.Failure?
    /// The failure report for a run that ended badly, and its sending — for
    /// the error window to show, and for the wrapp to wait on before it exits.
    private(set) var failureReport: FailureReport?
    private(set) var reportTask: Task<ReportOutcome, Never>?
    private let cleanupQueue = DispatchQueue(label: "com.gamewrapper.cleanup")
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What Wine and the game print, and what ScummVM prints: categories of
    /// their own, so they read apart from the launcher's lines about them.
    private nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Wine")
    private nonisolated let scummvmOutputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.ScummVM")
    
    init(config: GameConfig, gameMonitor: GameMonitor) {
        self.config = config
        self.gameMonitor = gameMonitor
    }
    
    // MARK: - Cleanup and Shutdown
    
    /// Cleanup game and Wine processes when quitting
    /// Returns true if async cleanup is needed (caller should wait), false if cleanup is immediate
    func performCleanup(completion: @escaping () -> Void) {
        logger.debug("[Cleanup/performCleanup] ENTERED performCleanup method")
        
        // Ensure cleanup only happens once
        cleanupQueue.sync {
            logger.debug("[Cleanup/performCleanup] Inside cleanupQueue.sync block")
            if cleanupCompleted {
                logger.debug("[Cleanup/performCleanup] Cleanup already completed, calling completion handler immediately")
                completion()
                return
            }
            logger.debug("[Cleanup/performCleanup] Setting cleanupCompleted = true")
            cleanupCompleted = true
        }
        logger.debug("[Cleanup/performCleanup] After cleanupQueue.sync block")
        
        logger.notice("[Cleanup] Starting cleanup process...")
        
        // Terminate the game process if it's still running
        if let process = currentProcess, process.isRunning {
            logger.notice("[Cleanup] Terminating game process (PID \(process.processIdentifier))...")
            process.terminate()
        }
        
        // For Wine games, we need to ensure wineserver is stopped
        if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-") {
            logger.debug("[Cleanup/performCleanup] Dispatching Wine server cleanup to background queue...")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.logger.debug("[Cleanup/performCleanup] Inside Wine cleanup async block")
                guard let self = self else {
                    self?.logger.debug("[Cleanup/performCleanup] self is nil, calling completion handler")
                    completion()
                    return
                }
                
                // Steam would keep the Wine session alive, and its sign-in
                // has to be saved and taken out of the wrapp on the way out.
                // Briefly: the quit fallback kills everything after 15s, and
                // Steam has been seen to ignore -shutdown when it's stuck.
                self.steam?.finish(timeout: 8)
                self.logger.debug("[Cleanup/performCleanup] Calling WineUtilities.waitTillWineserverStopped...")
                WineUtilities.waitTillWineserverStopped(at: self.config.appPath, customPrefixDir: self.config.winePrefix)
                self.logger.debug("[Cleanup/performCleanup] WineUtilities.waitTillWineserverStopped returned")
                self.logger.debug("[Cleanup/performCleanup] About to call completion handler")
                completion()
                logger.debug("[Cleanup/performCleanup] Completion handler called")
            }
            logger.debug("[Cleanup/performCleanup] Wine cleanup dispatched, exiting performCleanup method")
        } else {
            // Non-Wine games, cleanup is immediate
            logger.debug("[Cleanup/performCleanup] Non-Wine game, cleanup is immediate")
            logger.debug("[Cleanup/performCleanup] About to call completion handler")
            completion()
            logger.debug("[Cleanup/performCleanup] Completion handler called, exiting performCleanup method")
        }
    }
    
    // MARK: - Common Cleanup
    
    /// When the game was launched, for how long it ran.
    private var launchedAt = Date()
    /// Whether the game's own process was ever seen (always, for ScummVM).
    private var gameStarted = false
    /// The prefix's Documents, where the games keep their folders (a link to
    /// the wrapp's saves).
    private var documentsDirectory: URL {
        config.winePrefix.appendingPathComponent("drive_c/users/\(WineEnvironment.wineUsername)/Documents")
    }

    private func handleGameTermination(exitCode: Int32?, signal: Int32?, infoWindow: InfoWindowController?) {
        let ran = SubprocessWatch.duration(Date().timeIntervalSince(launchedAt))
        // The wrapp stopping the game on its way out (Cmd-Q, a SIGTERM to the
        // wrapp) is a quit, not a failure, whatever signal the game got.
        if cleanupQueue.sync(execute: { cleanupCompleted }) {
            logger.notice("■ Game stopped after \(ran), because the wrapp is quitting")
            infoWindow?.close()
            logger.notice("[Game Launcher] Game has terminated, returning control to app lifecycle manager")
            return
        }
        // Only Wine launches track the window (ScummVM has no diagnostics).
        let window = diagnostics.map { $0.hasSeenWindow ? ", after its window appeared" : ", before any window appeared" } ?? ""
        // The later Her Interactive games exit with whatever code MFC has
        // lying around, so for them a non-zero exit is judged by their own log.
        let cleanExitLog = gameStarted && signal == nil && (exitCode ?? 0) != 0
            ? HerEngineLog.cleanExitLog(inDocuments: documentsDirectory, since: launchedAt)
            : nil
        if !gameStarted {
            let how = signal.map { "was killed by \(SubprocessWatch.signalName($0))" } ?? "exited \(exitCode.map(String.init) ?? "?")"
            logger.error("■ The game never started: Wine's launcher \(how) after \(ran)")
        } else if let signal {
            logger.error("■ Game was killed by \(SubprocessWatch.signalName(signal)) after \(ran)\(window)")
        } else if let exitCode, let cleanExitLog {
            logger.notice("■ Game exited \(exitCode) after \(ran), a clean quit: its \(cleanExitLog.lastPathComponent) reports a good exit, and this engine's exit code means nothing")
        } else if let exitCode, exitCode != 0 {
            logger.error("■ Game exited \(exitCode) after \(ran)\(window) — a crash or an error on the way out")
        } else if exitCode != nil {
            logger.notice("■ Game exited 0 after \(ran)")
        } else {
            logger.notice("■ Game ended after \(ran) (exit status unknown)")
        }
        if let unexpectedQuit {
            logger.error("\(GameQuitCheck.failureMarker): nothing asked the game to quit, and \(unexpectedQuit.summary). \(unexpectedQuit.explanation)")
            for line in unexpectedQuit.wineErrors.suffix(10) {
                logger.error("    Wine: \(line)")
            }
        }

        let endedBadly = !gameStarted || signal != nil || ((exitCode ?? 0) != 0 && cleanExitLog == nil)
            || diagnostics?.hasSeenWindow == false || unexpectedQuit != nil
        if endedBadly {
            var files: [(String, String)] = []
            if let bundle = diagnostics?.lastBundle {
                files.append(("Diagnostics", bundle.path))
            }
            let summary = FailureSummary.log(logger, what: "Running \(config.gameTitle)", files: files)
            report(FailureReport(
                what: "Running the game", kind: failureKind(exitCode: exitCode, signal: signal),
                game: config.gameSlug, engine: config.gameEngine,
                tags: failureTags(exitCode: exitCode, signal: signal), summary: summary,
                diagnostics: diagnostics.map { diagnostics in { await diagnostics.bundleWhenComplete() } }
            ))
        }
        
        // Close info window if it's still open
        infoWindow?.close()
        
        logger.notice("[Game Launcher] Game has terminated, returning control to app lifecycle manager")
    }
    
    /// The person gave up on a launch that seemed stuck (the info window's
    /// possible-failure note) and is quitting: report it as the failure it
    /// probably is, since the game never exits to be reported on its own.
    /// Returns the report and its sending, for the info window to show.
    func reportStuckLaunch() -> (FailureReport, Task<ReportOutcome, Never>) {
        let ran = SubprocessWatch.duration(Date().timeIntervalSince(launchedAt))
        let window = diagnostics.map { $0.hasSeenWindow ? ", after its window appeared" : ", before any window appeared" } ?? ""
        logger.error("■ Gave up waiting for the launch after \(ran)\(window): the player quit while it seemed stuck")
        var files: [(String, String)] = []
        if let bundle = diagnostics?.lastBundle {
            files.append(("Diagnostics", bundle.path))
        }
        let summary = FailureSummary.log(logger, what: "Starting \(config.gameTitle)", files: files)
        let stuck = FailureReport(
            what: "Starting the game", kind: "stuck", game: config.gameSlug, engine: config.gameEngine,
            tags: failureTags(exitCode: nil, signal: nil), summary: summary,
            diagnostics: diagnostics.map { diagnostics in { await diagnostics.bundleWhenComplete() } }
        )
        report(stuck)
        return (stuck, reportTask ?? Task { .disabled })
    }

    /// How a run that ended badly ended, as a report's kind: the first of
    /// the checks above that it failed.
    private func failureKind(exitCode: Int32?, signal: Int32?) -> String {
        if unexpectedQuit != nil { return "quit-unexpectedly" }
        if !gameStarted { return "never-started" }
        if signal != nil { return "killed-by-signal" }
        if let exitCode, exitCode != 0 { return "exit-code" }
        return "no-window"
    }

    private func failureTags(exitCode: Int32?, signal: Int32?) -> [String: String] {
        var tags: [String: String] = [:]
        if let exitCode { tags["exit_code"] = String(exitCode) }
        if let signal { tags["signal"] = SubprocessWatch.signalName(signal) }
        if let reason = diagnostics?.lastReason { tags["diagnostics"] = reason.rawValue }
        return tags
    }

    /// Report at the detail the setting asks for, without holding up the
    /// caller: the error window shows the outcome when it comes.
    private func report(_ report: FailureReport) {
        failureReport = report
        reportTask = Task.detached { await FailureReporter.report(report) }
    }

    // MARK: - Game Launching
    
    func launchGame(infoWindow: InfoWindowController? = nil, debugMode: Bool = false) -> Int32 {
        launchedAt = Date()
        gameStarted = false
        LogContext.enterStage("Starting the game")
        if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-"),
           let gameExePath = getGameLaunchInfo(config).gameExePath {
            let gameExe = URL(fileURLWithPath: gameExePath)
            let graphics = GameGraphicsAPI(exeAt: gameExe)
            logger.notice("[Helpers] \(gameExe.lastPathComponent) draws with \(graphics.logDescription)\(graphics.mayUseCncDdraw ? "" : ", so cursor lock isn't needed")")
            helperReport = InProcessHelperReport(
                armingVariables: WineEnvironment.inProcessHelperVariables(gameExe: gameExe), logger: logger)
            quitCheck = GameQuitCheck(graphicsAPI: graphics, throughSteam: config.gameEngine.hasPrefix("wine-steam"))
        } else if config.gameEngine == "scummvm", !scummvmPuppetVariables.isEmpty {
            helperReport = InProcessHelperReport(armingVariables: scummvmPuppetVariables, logger: logger)
        }
        if config.gameEngine.hasPrefix("wine-steam") {
            LogContext.enterStage("Starting Steam")
            do {
                let helperReport = helperReport
                let quitCheck = quitCheck
                let status = steamStatusHandler(infoWindow)
                let started = try WrappSteam(config: config, status: status,
                                             onOutputLine: {
                                                 helperReport?.observe(line: $0)
                                                 quitCheck?.observe(line: $0)
                                             })
                steam = started  // from here a quit can stop it
                try started.waitUntilSignedIn(status: status)
            } catch WrappSteam.Failure.cancelled {
                logger.notice("[Steam] Quit while waiting for Steam to sign in")
                return -1
            } catch {
                reportSteamFailure(error)
                return -1
            }
            LogContext.enterStage("Starting the game")
            // The game's own start is timed from here, not from Steam's.
            launchedAt = Date()
        }
        // Launch the game process (engine-specific)
        let launchResult: (process: Process?, gamePid: Int32, gameExeName: String?)
        // Steam starts the game itself, so there's no launcher process of
        // ours to watch: the game is found, and watched, by its exe.
        let launchedBySteam = config.gameEngine == "wine-steam"

        switch config.gameEngine {
        case "wine":
            launchResult = launchWineProcess()
        case "wine-steam":
            launchResult = launchViaSteam()
        case _ where config.gameEngine.hasPrefix("wine-"):
            launchResult = launchWineProcess()
        case "scummvm":
            launchResult = launchScummVMProcess()
        default:
            logger.critical("ERROR: Unknown game engine: \(self.config.gameEngine)")
            return -1
        }
        
        guard launchResult.gamePid > 0 || (launchedBySteam && launchResult.gameExeName != nil) else {
            logger.critical("ERROR: Failed to launch game")
            steam?.finish(timeout: 90)
            return -1
        }
        
        var gamePid = launchResult.gamePid
        
        // Wait for game to start
        if let gameExeName = launchResult.gameExeName {
            logger.notice("[Game Launch] Waiting for game executable to start...")
            if let detectedPid = gameMonitor.waitForGameToStart(gameExeName: gameExeName, gamePid: gamePid, launcher: launchResult.process) {
                logger.notice("[Game Launch] Game executable detected with PID \(detectedPid)")
                gameStarted = true
                if launchedBySteam { gamePid = detectedPid }
                diagnostics?.gameStarted(pid: detectedPid)

                // Activate game window (Wine games only)
                if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-") {
                    logger.notice("[Game Launch] Activating game window...")
                    if gameMonitor.activateGameWindow(gamePid: detectedPid, infoWindow: infoWindow) {
                        diagnostics?.gameWindowAppeared()
                        quitCheck?.windowDidAppear()
                        helperReport?.gameWindowAppeared()
                    }
                }
            } else if launchedBySteam {
                logger.error("[Game Launch] Steam never started \(gameExeName)")
                diagnostics?.gameExited(exitCode: -1)
                steam?.finish(timeout: 90)
                releaseDesktop()
                handleGameTermination(exitCode: nil, signal: nil, infoWindow: infoWindow)
                return -1
            } else {
                logger.error("[Game Launch] \(gameExeName) was never seen running; waiting for Wine's launcher to finish")
            }
        } else {
            gameStarted = true
            // ScummVM - starts immediately
            _ = gameMonitor.waitForGameToStart(gameExeName: "scummvm", gamePid: gamePid)
        }
        
        // Hide wrapper app from dock now that game has started
        gameMonitor.hideWrapperFromDock()

        // Wait for ScummVM to fully initialize
        if config.gameEngine == "scummvm" {
            logger.notice("[Game Launch] Waiting 2 seconds for ScummVM to initialize...")
            Thread.sleep(forTimeInterval: 2.0)
        }
        
        // Hide info window now that game has started
        infoWindow?.notifyGameLoaded()
        if gameStarted {
            LogContext.enterStage("Playing")
        }
        
        
        // A logout or shutdown quits the game before the wrapp hears of it.
        let quitCheck = quitCheck
        let powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil
        ) { _ in quitCheck?.quitRequested("the Mac is logging out or shutting down") }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver) }

        // Wait for game to stop
        logger.notice("[Game Launch] Waiting for game to stop...")
        gameMonitor.waitForGameToStop(gamePid: gamePid, process: launchResult.process)
        // Judged straight away: how soon after a Wine error it came matters.
        // A wrapp that is quitting stopped the game itself, and a game killed
        // by a signal is already reported as one.
        if !cleanupQueue.sync(execute: { cleanupCompleted }), gameMonitor.exitSignal == nil {
            unexpectedQuit = quitCheck?.failure()
        }

        // Get exit code from GameMonitor which captured it safely
        let exitCode = gameMonitor.exitCode ?? 0
        diagnostics?.gameExited(exitCode: exitCode)
        steam?.finish(timeout: 90)
        releaseDesktop()
        
        // Handle game termination (just cleanup, no app lifecycle management)
        handleGameTermination(exitCode: gameMonitor.exitCode, signal: gameMonitor.exitSignal, infoWindow: infoWindow)
        
        return exitCode
    }
    
    // MARK: - Wine Game Launching
    
    private func launchWineProcess() -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        // Get game launch info
        let launchInfo = getGameLaunchInfo(config)
        
        logger.notice("Launching game: \(launchInfo.executable) with arguments: \(launchInfo.arguments.joined(separator: " "))")
        if let gameExeName = launchInfo.gameExeName {
            logger.notice("Game executable name: \(gameExeName)")
        }
        
        let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
        
        // Get Wine-specific environment variables
        let wineEnvVars = wine.wineSpecificEnvironmentVariables()
        
        // Export commands for running Wine by hand against this prefix, as one
        // entry at debug: needed when reproducing, noise otherwise.
        let exports = wineEnvVars.sorted(by: { $0.key < $1.key }).map { key, value in
            "export \(key)=\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        logger.debug("Wine environment, for running Wine by hand:\n\(exports.joined(separator: "\n"))")

        prepareDesktop(wine)

        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        logger.debug("Full command: \(fullCommand)")
        
        // Launch the game
        logger.notice("[Wine] Launching game process...")
        
        // Capture Wine's stdout/stderr and log them
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        let process: Process
        do {
            // For Wine, we need to pass the game exe path, not the wine binary
            // The working directory change and wine binary call are handled by runWindowsExecutableWithStart
            guard let gameExeUnixPath = launchInfo.gameExePath else {
                logger.critical("ERROR: gameExePath is nil for Wine game")
                return (nil, -1, nil)
            }
            
            process = try wine.runWindowsExecutableWithStart(
                exePath: gameExeUnixPath,
                arguments: [],
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
        } catch {
            logger.critical("ERROR: Failed to launch game: \(error)")
            return (nil, -1, nil)
        }
        
        // Stream Wine output line-by-line through the logger (reaches the
        // terminal, the log window and the export; survives chunk splits).
        // Diagnostics sees the same lines, to keep recent context and spot crashes.
        let diagnostics = StartupDiagnostics(gameSlug: config.gameSlug, gameTitle: config.gameTitle)
        diagnostics.wineLaunched()
        self.diagnostics = diagnostics
        let helperReport = helperReport
        let quitCheck = quitCheck
        let observe: @Sendable (String) -> Void = { line in
            diagnostics.observe(line: line)
            helperReport?.observe(line: line)
            quitCheck?.observe(line: line)
        }
        ProcessLineLogger.attach(to: outputPipe, logger: wineOutputLogger, level: .notice, onLine: observe)
        ProcessLineLogger.attach(to: errorPipe, logger: wineOutputLogger, level: .warning, onLine: observe)
        
        logger.notice("[Wine] Game process started with PID \(process.processIdentifier)")
        
        // Store the process reference
        self.currentProcess = process
        
        return (process, process.processIdentifier, launchInfo.gameExeName)
    }
    
    // MARK: - Steam

    /// Have Steam start the game (`-applaunch`), for DRM that insists on it.
    private func launchViaSteam() -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        let launchInfo = getGameLaunchInfo(config)
        guard let steam, let appID = config.steamGameId.flatMap({ Int($0) }) else {
            logger.critical("ERROR: no Steam app ID for a game launched through Steam")
            return (nil, -1, nil)
        }
        do {
            try steam.client.launch(appID: appID)
        } catch {
            logger.critical("ERROR: Couldn't ask Steam to launch the game: \(error.localizedDescription)")
            return (nil, -1, nil)
        }
        let diagnostics = StartupDiagnostics(gameSlug: config.gameSlug, gameTitle: config.gameTitle)
        diagnostics.wineLaunched()
        self.diagnostics = diagnostics
        return (nil, 0, launchInfo.gameExeName)
    }

    private func reportSteamFailure(_ error: Error) {
        let (title, detail): (String, String)
        switch error {
        case WrappSteam.Failure.inUse(let holder):
            (title, detail) = ("Another game is using Steam",
                               "\(holder.map { "\($0) has" } ?? "Another game has") Steam open. Quit it, then open \(config.gameTitle) again.")
        case WrappSteam.Failure.signInTimedOut:
            (title, detail) = ("Steam didn't sign in", "\(config.gameTitle) needs Steam signed in to start. Open it again to have another go.")
        default:
            (title, detail) = ("Couldn't start Steam", error.localizedDescription)
        }
        logger.critical("[Steam] \(title): \(detail)")
        let summary = FailureSummary.log(logger, what: "Starting Steam for \(config.gameTitle)", files: [])
        report(FailureReport(what: "Starting Steam", error: error, game: config.gameSlug,
                             engine: config.gameEngine, summary: summary))
        DispatchQueue.main.sync { showAlert(message: title, informativeText: detail) }
    }

    /// Show Steam's progress in the loading window. Once signed in, what
    /// starts the game is Steam (`wine-steam`) or the wrapp, with Steam
    /// running (`wine-steam-silent`).
    private func steamStatusHandler(_ infoWindow: InfoWindowController?) -> (WrappSteam.Status) -> Void {
        let title = config.gameTitle
        let launchedBySteam = config.gameEngine == "wine-steam"
        return { status in
            switch status {
            case .starting: infoWindow?.setStage(.startingSteam)
            case .waitingForSignIn: infoWindow?.setStage(.signingInToSteam)
            case .signedIn: infoWindow?.setStage(launchedBySteam ? .steamStartingGame(title: title) : .startingGame(title: title))
            }
        }
    }

    // MARK: - Wine Desktop

    /// Start Wine's desktop and wait until it has registered the display
    /// devices, before the game runs. There is no deadline here that matters —
    /// the info window stays up meanwhile. See `WineDesktop`.
    private func prepareDesktop(_ wine: WineEnvironment) {
        // Debug switch, for comparing against Wine's own on-demand start.
        guard ProcessInfo.processInfo.environment["SECOND_CHANCE_PRESTART_DESKTOP"] != "0" else {
            logger.notice("[Desktop] Not pre-starting the desktop (SECOND_CHANCE_PRESTART_DESKTOP=0)")
            return
        }
        desktop = WineDesktop.start(wine, logger: logger, outputLogger: wineOutputLogger)
    }

    /// Let the pre-started desktop shut down once the game has exited, or it
    /// keeps the whole Wine session alive. See `WineDesktop.release`.
    private func releaseDesktop() {
        guard let desktop else { return }
        self.desktop = nil
        logger.notice("[Desktop] Game exited")
        desktop.release()
    }

    // MARK: - ScummVM Game Launching

    /// When WrappPuppeteer started the wrapp, what loads the in-process
    /// helpers' puppet control into scummvm, so WrappPuppeteer can capture
    /// and click the game without any permission. Wine games get it through
    /// winemac.so; scummvm is an ordinary binary (ad-hoc signed, no hardened
    /// runtime), so dyld inserts the dylib. The other helpers stay unarmed in
    /// it, since their variables aren't set. Empty for every player's launch.
    /// See docs/wine-in-process-helpers.md.
    private var scummvmPuppetVariables: [String: String] {
        guard WineEnvironment.puppetDirectory() != nil else { return [:] }
        let dylib = config.appPath.appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib").path
        // dyld kills a process whose inserted dylib is missing, so a wrapp
        // built without it runs the game without puppet control instead.
        guard FileManager.default.fileExists(atPath: dylib) else {
            logger.error("[Helpers] Puppet control can't be loaded into scummvm: \(dylib) is missing")
            return [:]
        }
        return ["DYLD_INSERT_LIBRARIES": dylib, "PUPPET_CONTROL_EXE": "scummvm"]
    }
    
    private func launchScummVMProcess() -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        // Get game launch info
        let launchInfo = getGameLaunchInfo(config)
        
        logger.notice("ScummVM binary: \(launchInfo.executable)")
        logger.notice("Launching ScummVM with arguments:")
        for arg in launchInfo.arguments {
            logger.notice("  \(arg)")
        }
        
        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        logger.notice("Full command: \(fullCommand)")
        
        // Execute ScummVM with output captured line-by-line through the
        // logger (terminal users still see it via stderr when isatty, and it
        // now also reaches the log window and the export).
        let task = TaggedProcess(logger: scummvmOutputLogger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        let puppetVariables = scummvmPuppetVariables
        if !puppetVariables.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(puppetVariables) { $1 }
            let helperReport = helperReport
            task.onLine = { helperReport?.observe(line: $0) }
        }
        
        do {
            try task.run()
            logger.notice("[ScummVM] Game process started with PID \(task.processIdentifier)")
            
            // Store the process reference
            self.currentProcess = task.process
            
            return (task.process, task.processIdentifier, nil)  // No gameExeName for ScummVM
        } catch {
            logger.critical("ERROR: Failed to launch ScummVM: \(error.localizedDescription)")
            return (nil, -1, nil)
        }
    }
}
