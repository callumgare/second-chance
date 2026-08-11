//
//  main.swift
//  GameWrapper
//
//  Main entry point for Nancy Drew game wrappers

import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "com.secondchance.gamewrapper", category: "main")

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
        alert.informativeText = "Game: \(config.appPath.lastPathComponent)\nEngine: \(config.gameEngine)\nPrefix: \(config.winePrefix.path)\n\nLaunch Command: \(getGameLaunchInfo(config).formatLaunchCommand())\n\nDebug Mode: \(debugStatus)"
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
        default:  // Cancel
            return (false, debugModeEnabled)
        }
    }
}

func launchWineShell(_ config: GameConfig) {
    logger.notice("Opening Wine shell...")
    
    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    let wineEnvVars = wine.wineSpecificEnvironmentVariables()
    
    logger.notice("Wine prefix: \(config.winePrefix, privacy: .public)")
    logger.notice("Wine environment variables: \(wineEnvVars, privacy: .public)")
    
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
    script += "echo '  winecfg                                          (Wine configuration)'\n"
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
        
        logger.notice("Debug shell opened in Terminal")
    } catch {
        logger.error("Error creating shell command file: \(error, privacy: .public)")
    }
}

func launchScummvmShell(_ config: GameConfig) {
    logger.notice("Opening ScummVM shell...")
    
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
        
        logger.notice("Debug shell opened in Terminal")
    } catch {
        logger.error("Error creating shell command file: \(error, privacy: .public)")
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
        logger.error("Warning: Unknown game engine \(config.gameEngine, privacy: .public), attempting Wine shell")
        launchWineShell(config)
    }
}

func launchWineControlPanel(_ config: GameConfig) {
    logger.notice("Launching Wine control panel...")
    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    wine.runExecutable("wine", arguments: ["control"])
}

func launchWineConfig(_ config: GameConfig) {
    logger.notice("Launching Wine config...")
    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    wine.runExecutable("winecfg")
}

func showWinePrefixInFinder(_ config: GameConfig) {
    logger.notice("Opening Wine prefix in Finder: \(config.winePrefix.path, privacy: .public)")
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
    let config: GameConfig
    let gameLauncher: GameLauncher?
    var isCleaningUp = false
    
    init(config: GameConfig, gameLauncher: GameLauncher?) {
        self.config = config
        self.gameLauncher = gameLauncher
        super.init()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.notice("[Cleanup/AppDelegate] applicationShouldTerminate called")
        
        // Prevent multiple cleanup attempts
        guard !isCleaningUp else {
            logger.notice("[Cleanup/AppDelegate] Already cleaning up, returning .terminateNow")
            return .terminateNow
        }
        
        logger.notice("[Cleanup/AppDelegate] Setting isCleaningUp = true")
        isCleaningUp = true
        
        guard let gameLauncher = gameLauncher else {
            logger.notice("[Cleanup/AppDelegate] No gameLauncher, returning .terminateNow")
            return .terminateNow
        }
        
        logger.notice("[Cleanup/AppDelegate] Application terminating, performing cleanup...")
        
        // Perform cleanup and wait for completion
        logger.notice("[Cleanup/AppDelegate] About to call gameLauncher.performCleanup...")
        gameLauncher.performCleanup {
            logger.notice("[Cleanup/AppDelegate] Inside performCleanup completion handler")
            DispatchQueue.main.async {
                logger.notice("[Cleanup/AppDelegate] On main queue, about to call NSApp.reply")
                logger.notice("[Cleanup] All cleanup complete, terminating application")
                NSApp.reply(toApplicationShouldTerminate: true)
                logger.notice("[Cleanup/AppDelegate] NSApp.reply(toApplicationShouldTerminate: true) called")
            }
        }
        
        logger.notice("[Cleanup/AppDelegate] Returning .terminateLater")
        // Return later - we'll call reply when cleanup is done
        return .terminateLater
    }
}

// MARK: - Main

func main() {
    // Get app path for prefix determination
    guard let executablePath = ProcessInfo.processInfo.arguments.first else {
        showAlert(message: "Configuration Error", informativeText: "Could not determine executable path.")
        exit(1)
    }
    
    let executableURL = URL(fileURLWithPath: executablePath)
    let appPath = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let infoPlistPath = appPath.appendingPathComponent("Contents/Info.plist")
    
    // Get bundle ID for prefix path
    guard let bundleId = readPlist(at: infoPlistPath, key: "CFBundleIdentifier") else {
        showAlert(message: "Configuration Error", informativeText: "Could not read bundle identifier.")
        exit(1)
    }
    
    // Determine wine prefix (will use cache if read-only)
    let winePrefix = getWinePrefix(appPath: appPath, bundleId: bundleId)
    
    // `wine` subcommand: when the bundle binary is invoked directly from a
    // terminal, act as a thin pass-through to the bundled Wine binary for this
    // game's prefix, then exit with Wine's status. Stdio is inherited, so output
    // streams to the calling terminal. Examples:
    //   /path/Game.app/Contents/MacOS/GameWrapper wine --version
    //   /path/Game.app/Contents/MacOS/GameWrapper wine '\start' explorer.exe
    // Returns `nil` for normal launches (double-click, `open`, `--debug`, …),
    // so the regular game-launch flow below is unchanged.
    if let wineArgs = extractWineSubcommand(from: CommandLine.arguments) {
        let wine = WineEnvironment(appPath: appPath, customPrefixDir: winePrefix)
        let exitCode = wine.runExecutable("wine", arguments: wineArgs)
        exit(exitCode)
    }
    
    // Load configuration
    guard let config = loadConfig(customWinePrefix: winePrefix) else {
        showAlert(message: "Configuration Error", informativeText: "Could not load game configuration. Please check the app bundle.")
        exit(1)
    }
    
    logger.notice("Game wrapper starting...")
    logger.notice("App path: \(config.appPath.path, privacy: .public)")
    logger.notice("Game engine: \(config.gameEngine, privacy: .public)")
    logger.notice("Game exe: \(config.gameExePath, privacy: .public)")
    logger.notice("Wine prefix: \(config.winePrefix.path, privacy: .public)")
    logger.notice("App support: \(config.appSupportPath.path, privacy: .public)")
    
    // Check if wineserver is already running for this prefix
    let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
    if wine.isWineserverRunning() {
        logger.error("WARNING ⚠️: Detected running wineserver process for this prefix")
        
        // Initialize NSApplication if not already done
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        
        let alert = NSAlert()
        alert.messageText = "Wine Process Detected"
        alert.informativeText = "A Wine server process (wineserver) is already running for this game's prefix. This may cause conflicts.\n\nWould you like to quit the Wine server before continuing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Wine Server")
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Cancel Launch")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:  // Quit Wine Server
            logger.notice("User chose to quit Wine server")
            let exitStatus = wine.stopWineserver()
            if exitStatus == 0 {
                logger.notice("✓ Wine server terminated successfully")
                // Wait a moment for cleanup
                Thread.sleep(forTimeInterval: 0.5)
            } else {
                logger.error("⚠️  Wine server termination returned exit code: \(exitStatus, privacy: .public)")
            }
        case .alertSecondButtonReturn:  // Continue Anyway
            logger.notice("User chose to continue with Wine server running")
        default:  // Cancel Launch
            logger.notice("Launch cancelled by user")
            exit(0)
        }
    }
    
    // Check for debug mode
    var debugMode = false
    var shouldShowDebugSettings = false
    
    for arg in CommandLine.arguments {
        if arg == "--debug" {
            debugMode = true
            logger.notice("--debug flag detected - debug mode enabled")
        } else if arg == "--debug-options" {
            shouldShowDebugSettings = true
        }
    }
    
    // Show debug settings if requested
    if shouldShowDebugSettings {
        if debugMode {
            logger.notice("--debug and --debug-options flags detected - showing debug settings with debug mode pre-enabled")
        } else {
            logger.notice("--debug-options flag detected - showing debug settings")
        }
        let (shouldContinue, debugModeFromDialog) = showDebugSettings(config, initialDebugMode: debugMode)
        debugMode = debugModeFromDialog
        if !shouldContinue {
            logger.notice("Launch cancelled from debug settings")
            exit(0)
        }
    }
    
    if debugMode {
        logger.notice("Debug mode enabled - log window will be shown")
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
    // Only show save warning for Wine games (ScummVM games are more stable)
    let saveWarningEnabled = config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-")
    let infoWindow = InfoWindowController(gameTitle: config.gameTitle, appSupportPath: config.appSupportPath, saveWarningEnabled: saveWarningEnabled)
    globalInfoWindow = infoWindow
    
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
    
    logger.notice("Starting game...")
    
    // Setup Wine environment (only for Wine games)
    if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-steam") {
        do {
            try mountDirectoryIntoWine(config, hostPath: config.appSupportPath, driveLetter: "a")
        } catch {
            logger.fault("ERROR: Failed to mount directory into Wine: \(error, privacy: .public)")
            showAlert(message: "Configuration Error", informativeText: "Failed to mount directory into Wine: \(error.localizedDescription)")
            exit(1)
        }
        
        // Link save directory
        let documentsPath = config.winePrefix.appendingPathComponent("drive_c/users/\(WineEnvironment.wineUsername)/Documents")
        do {
            var targetPath: URL? = documentsPath
            
            // Check if documentsPath exists (including broken symlinks)
            logger.notice("Checking if Documents directory exists at: \(documentsPath.path, privacy: .public)")
            
            // Check for symlink existence (works even if target doesn't exist)
            let attributes = try? FileManager.default.attributesOfItem(atPath: documentsPath.path)
            logger.notice("Attributes: \(String(describing: attributes), privacy: .public)")
            let itemExists = attributes != nil
            
            if itemExists {
                logger.notice("Documents directory exists at: \(documentsPath.path, privacy: .public)")
            } else {
                logger.notice("Documents directory does not exist at: \(documentsPath.path, privacy: .public)")
            }
            
            if itemExists {
                do {
                    // Try to remove it
                    try FileManager.default.removeItem(at: documentsPath)
                } catch {
                    // Check if it's a permission error
                    logger.fault("ERROR: \(error, privacy: .public)")
                    logger.notice("Unable to remove Documents so treating as as a symlink...")
                    
                    // Check if it's a symlink and get where it points
                    do {
                        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: documentsPath.path)
                        logger.notice("Documents is a symlink pointing to: \(destination, privacy: .public)")
                        
                        // Convert destination to absolute URL
                        if destination.hasPrefix("/") {
                            targetPath = URL(fileURLWithPath: destination)
                        } else {
                            // It's a relative path, resolve it relative to documentsPath's parent
                            targetPath = documentsPath.deletingLastPathComponent().appendingPathComponent(destination).standardized
                        }
                        
                        // If targetPath exists, set it to nil
                        if let resolvedPath = targetPath, FileManager.default.fileExists(atPath: resolvedPath.path) {
                            logger.notice("Target path already exists, skipping")
                            targetPath = nil
                        } else if let resolvedPath = targetPath {
                            logger.notice("Will create new symlink at: \(resolvedPath.path, privacy: .public)")
                        }
                    } catch {
                        logger.fault("ERROR: Could not read symlink destination: \(error, privacy: .public)")
                        throw error
                    }
                }
            }
            
            if let targetPath = targetPath {
                try FileManager.default.createSymbolicLink(at: targetPath, withDestinationURL: config.appSupportPath)
            }
        } catch {
            logger.fault("ERROR: Failed to create symbolic link for Documents directory: \(error, privacy: .public)")
            showAlert(message: "Configuration Error", informativeText: "Failed to create symbolic link for save directory: \(error.localizedDescription)")
            exit(1)
        }
    }
    
    // Record game engine on first run
    let gameEngineFile = config.appSupportPath.appendingPathComponent("game-engine")
    if !FileManager.default.fileExists(atPath: gameEngineFile.path) {
        try? config.gameEngine.write(to: gameEngineFile, atomically: true, encoding: .utf8)
    }
    
    // Launch based on engine type
    func launchGameAsync() {
        DispatchQueue.global(qos: .userInitiated).async {
            let exitCode = gameLauncher.launchGame(infoWindow: infoWindow, debugMode: debugMode)

            if exitCode != 0 {
                logger.error("Game exited with non-zero status: \(exitCode, privacy: .public)")
                infoWindow.showError(exitCode: exitCode)
                return
            }

            if !debugMode {
                logger.notice("[App Lifecycle] Game ended, exiting cleanly...")
                exit(0)
            } else {
                logger.notice("[Debug Mode] Game ended. Wrapper staying open. Press Cmd+Q to quit.")
            }
        }
    }

    switch config.gameEngine {
    case "wine":
        if infoWindow.isShowingWarning {
            logger.notice("Waiting for user to confirm save warning before launching game...")
            infoWindow.onWarningConfirmed = {
                logger.notice("Warning confirmed, launching game...")
                launchGameAsync()
            }
        } else {
            logger.notice("No warning to show, launching game immediately...")
            launchGameAsync()
        }

    case "wine-steam", "wine-steam-silent":
        logger.fault("ERROR: Steam engine not yet implemented in Swift runtime")
        logger.fault("Please use the bash runtime for Steam games")
        exit(1)

    case "scummvm":
        logger.notice("Launching ScummVM game...")
        launchGameAsync()

    default:
        logger.fault("ERROR: Unknown game engine: \(config.gameEngine, privacy: .public)")
        exit(1)
    }

    NSApp.run()
}

// Run the main function
main()
