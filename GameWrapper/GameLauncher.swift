//
//  GameLauncher.swift
//  GameWrapper
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
    private let cleanupQueue = DispatchQueue(label: "com.gamewrapper.cleanup")
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.GameWrapper.GameLauncher")
    
    init(config: GameConfig, gameMonitor: GameMonitor) {
        self.config = config
        self.gameMonitor = gameMonitor
    }
    
    // MARK: - Cleanup and Shutdown
    
    /// Cleanup game and Wine processes when quitting
    /// Returns true if async cleanup is needed (caller should wait), false if cleanup is immediate
    func performCleanup(completion: @escaping () -> Void) {
        logger.notice("[Cleanup/performCleanup] ENTERED performCleanup method")
        
        // Ensure cleanup only happens once
        cleanupQueue.sync {
            logger.notice("[Cleanup/performCleanup] Inside cleanupQueue.sync block")
            if cleanupCompleted {
                logger.notice("[Cleanup/performCleanup] Cleanup already completed, calling completion handler immediately")
                completion()
                return
            }
            logger.notice("[Cleanup/performCleanup] Setting cleanupCompleted = true")
            cleanupCompleted = true
        }
        logger.notice("[Cleanup/performCleanup] After cleanupQueue.sync block")
        
        logger.notice("[Cleanup] Starting cleanup process...")
        
        // Terminate the game process if it's still running
        if let process = currentProcess, process.isRunning {
            logger.notice("[Cleanup] Terminating game process (PID \(process.processIdentifier))...")
            process.terminate()
        }
        
        // For Wine games, we need to ensure wineserver is stopped
        if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-") {
            logger.notice("[Cleanup/performCleanup] Dispatching Wine server cleanup to background queue...")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.logger.notice("[Cleanup/performCleanup] Inside Wine cleanup async block")
                guard let self = self else {
                    self?.logger.notice("[Cleanup/performCleanup] self is nil, calling completion handler")
                    completion()
                    return
                }
                
                self.logger.notice("[Cleanup/performCleanup] Calling WineUtilities.waitTillWineserverStopped...")
                WineUtilities.waitTillWineserverStopped(at: self.config.appPath, customPrefixDir: self.config.winePrefix)
                self.logger.notice("[Cleanup/performCleanup] WineUtilities.waitTillWineserverStopped returned")
                self.logger.notice("[Cleanup/performCleanup] About to call completion handler")
                completion()
                logger.notice("[Cleanup/performCleanup] Completion handler called")
            }
            logger.notice("[Cleanup/performCleanup] Wine cleanup dispatched, exiting performCleanup method")
        } else {
            // Non-Wine games, cleanup is immediate
            logger.notice("[Cleanup/performCleanup] Non-Wine game, cleanup is immediate")
            logger.notice("[Cleanup/performCleanup] About to call completion handler")
            completion()
            logger.notice("[Cleanup/performCleanup] Completion handler called, exiting performCleanup method")
        }
    }
    
    // MARK: - Common Cleanup
    
    private func handleGameTermination(exitCode: Int32, infoWindow: InfoWindowController?) {
        logger.error("[Process Monitor] ⚠️ Game process termination detected!")
        logger.notice("[Process Monitor] Exit code: \(exitCode)")
        
        // Print warning if game didn't exit cleanly
        if exitCode != 0 {
            logger.error("⚠️ WARNING: Game did not exit cleanly! Exit code: \(exitCode)")
            logger.error("This may indicate a crash or error during shutdown.")
        }
        
        // Close info window if it's still open
        infoWindow?.close()
        
        logger.notice("[Game Launcher] Game has terminated, returning control to app lifecycle manager")
    }
    
    // MARK: - Game Launching
    
    func launchGame(infoWindow: InfoWindowController? = nil, debugMode: Bool = false) -> Int32 {
        // Launch the game process (engine-specific)
        let launchResult: (process: Process?, gamePid: Int32, gameExeName: String?)
        
        switch config.gameEngine {
        case "wine":
            launchResult = launchWineProcess()
        case _ where config.gameEngine.hasPrefix("wine-"):
            launchResult = launchWineProcess()
        case "scummvm":
            launchResult = launchScummVMProcess()
        default:
            logger.critical("ERROR: Unknown game engine: \(self.config.gameEngine)")
            return -1
        }
        
        guard launchResult.gamePid > 0 else {
            logger.critical("ERROR: Failed to launch game")
            return -1
        }
        
        let gamePid = launchResult.gamePid
        
        // Wait for game to start
        if let gameExeName = launchResult.gameExeName {
            logger.notice("[Game Launch] Waiting for game executable to start...")
            if let detectedPid = gameMonitor.waitForGameToStart(gameExeName: gameExeName, gamePid: gamePid) {
                logger.notice("[Game Launch] Game executable detected with PID \(detectedPid)")
                
                // Activate game window (Wine games only)
                if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-") {
                    logger.notice("[Game Launch] Activating game window...")
                    gameMonitor.activateGameWindow(gamePid: detectedPid, infoWindow: infoWindow)
                }
            } else {
                logger.notice("[Game Launch] Failed to detect game executable, but will continue monitoring process")
            }
        } else {
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
        
        
        // Wait for game to stop
        logger.notice("[Game Launch] Waiting for game to stop...")
        gameMonitor.waitForGameToStop(gamePid: gamePid, process: launchResult.process)
        
        // Get exit code from GameMonitor which captured it safely
        let exitCode = gameMonitor.exitCode ?? 0
        
        // Handle game termination (just cleanup, no app lifecycle management)
        handleGameTermination(exitCode: exitCode, infoWindow: infoWindow)
        
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
        
        // Print export commands for manual use
        logger.notice("Wine-specific environment variables (for manual debugging):")
        logger.notice("# These are the custom env vars needed for Wine to work properly")
        for (key, value) in wineEnvVars.sorted(by: { $0.key < $1.key }) {
            let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
            logger.notice("export \(key)=\"\(escapedValue)\"")
        }
        
        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        logger.notice("Full command: \(fullCommand)")
        
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
        ProcessLineLogger.attach(to: outputPipe, logger: logger, level: .notice)
        ProcessLineLogger.attach(to: errorPipe, logger: logger, level: .error)
        
        logger.notice("[Wine] Game process started with PID \(process.processIdentifier)")
        
        // Store the process reference
        self.currentProcess = process
        
        return (process, process.processIdentifier, launchInfo.gameExeName)
    }
    
    // MARK: - ScummVM Game Launching
    
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
        let task = TaggedProcess(logger: logger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        
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
