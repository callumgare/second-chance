//
//  GameLauncher.swift
//  GameWrapper
//
//  Game launching logic for Nancy Drew game wrappers

import Foundation
import AppKit

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
    
    init(config: GameConfig, gameMonitor: GameMonitor) {
        self.config = config
        self.gameMonitor = gameMonitor
    }
    
    // MARK: - Cleanup and Shutdown
    
    /// Cleanup game and Wine processes when quitting
    /// Returns true if async cleanup is needed (caller should wait), false if cleanup is immediate
    func performCleanup(completion: @escaping () -> Void) {
        print("[Cleanup/performCleanup] ENTERED performCleanup method")
        
        // Ensure cleanup only happens once
        cleanupQueue.sync {
            print("[Cleanup/performCleanup] Inside cleanupQueue.sync block")
            if cleanupCompleted {
                print("[Cleanup/performCleanup] Cleanup already completed, calling completion handler immediately")
                completion()
                return
            }
            print("[Cleanup/performCleanup] Setting cleanupCompleted = true")
            cleanupCompleted = true
        }
        print("[Cleanup/performCleanup] After cleanupQueue.sync block")
        
        print("[Cleanup] Starting cleanup process...")
        
        // Terminate the game process if it's still running
        if let process = currentProcess, process.isRunning {
            print("[Cleanup] Terminating game process (PID \(process.processIdentifier))...")
            process.terminate()
        }
        
        // For Wine games, we need to ensure wineserver is stopped
        if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-") {
            print("[Cleanup/performCleanup] Dispatching Wine server cleanup to background queue...")
            DispatchQueue.global(qos: .utility).async { [weak self] in
                print("[Cleanup/performCleanup] Inside Wine cleanup async block")
                guard let self = self else {
                    print("[Cleanup/performCleanup] self is nil, calling completion handler")
                    completion()
                    return
                }
                
                print("[Cleanup/performCleanup] Calling WineUtilities.waitTillWineserverStopped...")
                WineUtilities.waitTillWineserverStopped(at: self.config.appPath, customPrefixDir: self.config.winePrefix)
                print("[Cleanup/performCleanup] WineUtilities.waitTillWineserverStopped returned")
                print("[Cleanup/performCleanup] About to call completion handler")
                completion()
                print("[Cleanup/performCleanup] Completion handler called")
            }
            print("[Cleanup/performCleanup] Wine cleanup dispatched, exiting performCleanup method")
        } else {
            // Non-Wine games, cleanup is immediate
            print("[Cleanup/performCleanup] Non-Wine game, cleanup is immediate")
            print("[Cleanup/performCleanup] About to call completion handler")
            completion()
            print("[Cleanup/performCleanup] Completion handler called, exiting performCleanup method")
        }
    }
    
    // MARK: - Common Cleanup
    
    private func handleGameTermination(exitCode: Int32, infoWindow: InfoWindowController?) {
        print("\n[Process Monitor] ⚠️ Game process termination detected!")
        print("[Process Monitor] Exit code: \(exitCode)")
        
        // Print warning if game didn't exit cleanly
        if exitCode != 0 {
            print("⚠️ WARNING: Game did not exit cleanly! Exit code: \(exitCode)")
            print("This may indicate a crash or error during shutdown.")
        }
        
        // Flush to ensure output is written immediately
        fflush(stdout)
        
        // Close info window if it's still open
        infoWindow?.close()
        
        print("[Game Launcher] Game has terminated, returning control to app lifecycle manager")
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
            print("ERROR: Unknown game engine: \(config.gameEngine)")
            return -1
        }
        
        guard launchResult.gamePid > 0 else {
            print("ERROR: Failed to launch game")
            return -1
        }
        
        let gamePid = launchResult.gamePid
        
        // Wait for game to start
        if let gameExeName = launchResult.gameExeName {
            print("\n[Game Launch] Waiting for game executable to start...")
            if let detectedPid = gameMonitor.waitForGameToStart(gameExeName: gameExeName, gamePid: gamePid) {
                print("[Game Launch] Game executable detected with PID \(detectedPid)")
                
                // Activate game window (Wine games only)
                if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-") {
                    print("\n[Game Launch] Activating game window...")
                    gameMonitor.activateGameWindow(gamePid: detectedPid, infoWindow: infoWindow)
                }
            } else {
                print("[Game Launch] Failed to detect game executable, but will continue monitoring process")
            }
        } else {
            // ScummVM - starts immediately
            _ = gameMonitor.waitForGameToStart(gameExeName: "scummvm", gamePid: gamePid)
        }
        
        // Hide wrapper app from dock now that game has started
        gameMonitor.hideWrapperFromDock()

        // Wait for ScummVM to fully initialize
        if config.gameEngine == "scummvm" {
            print("[Game Launch] Waiting 2 seconds for ScummVM to initialize...")
            Thread.sleep(forTimeInterval: 2.0)
        }
        
        // Hide info window now that game has started
        infoWindow?.notifyGameLoaded()
        
        
        // Wait for game to stop
        print("\n[Game Launch] Waiting for game to stop...")
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
        
        print("Launching game: \(launchInfo.executable) with arguments: \(launchInfo.arguments.joined(separator: " "))")
        if let gameExeName = launchInfo.gameExeName {
            print("Game executable name: \(gameExeName)")
        }
        
        let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
        
        // Get Wine-specific environment variables
        let wineEnvVars = wine.wineSpecificEnvironmentVariables()
        
        // Print export commands for manual use
        print("\nWine-specific environment variables (for manual debugging):")
        print("# These are the custom env vars needed for Wine to work properly")
        for (key, value) in wineEnvVars.sorted(by: { $0.key < $1.key }) {
            let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
            print("export \(key)=\"\(escapedValue)\"")
        }
        print("")
        
        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        print("Full command: \(fullCommand)")
        
        // Launch the game
        print("\n[Wine] Launching game process...")
        
        // Capture Wine's stdout/stderr and log them
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        let process: Process
        do {
            // For Wine, we need to pass the game exe path, not the wine binary
            // The working directory change and wine binary call are handled by runWindowsExecutableWithStart
            guard let gameExeUnixPath = launchInfo.gameExePath else {
                print("ERROR: gameExePath is nil for Wine game")
                return (nil, -1, nil)
            }
            
            process = try wine.runWindowsExecutableWithStart(
                exePath: gameExeUnixPath,
                arguments: [],
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
        } catch {
            print("ERROR: Failed to launch game: \(error)")
            return (nil, -1, nil)
        }
        
        // Read Wine output in background
        DispatchQueue.global(qos: .utility).async {
            let handle = outputPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.split(separator: "\n")
                    for line in lines {
                        print("Wine: \(line)")
                    }
                }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            let handle = errorPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let output = String(data: data, encoding: .utf8) {
                    let lines = output.split(separator: "\n")
                    for line in lines {
                        print("Wine stderr: \(line)")
                    }
                }
            }
        }
        
        print("[Wine] Game process started with PID \(process.processIdentifier)")
        
        // Store the process reference
        self.currentProcess = process
        
        return (process, process.processIdentifier, launchInfo.gameExeName)
    }
    
    // MARK: - ScummVM Game Launching
    
    private func launchScummVMProcess() -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        // Get game launch info
        let launchInfo = getGameLaunchInfo(config)
        
        print("ScummVM binary: \(launchInfo.executable)")
        print("Launching ScummVM with arguments:")
        for arg in launchInfo.arguments {
            print("  \(arg)")
        }
        
        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        print("Full command: \(fullCommand)")
        
        // Execute ScummVM
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        
        // Pass through stdout/stderr for real-time output
        task.standardOutput = FileHandle.standardOutput
        task.standardError = FileHandle.standardError
        
        do {
            try task.run()
            print("[ScummVM] Game process started with PID \(task.processIdentifier)")
            
            // Store the process reference
            self.currentProcess = task
            
            return (task, task.processIdentifier, nil)  // No gameExeName for ScummVM
        } catch {
            print("ERROR: Failed to launch ScummVM: \(error.localizedDescription)")
            return (nil, -1, nil)
        }
    }
}
