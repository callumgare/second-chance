#!/usr/bin/env swift
//
//  main.swift
//  GameWrapperRuntime
//
//  Runtime executable for Nancy Drew game wrappers
//  Replaces the bash entrypoint.sh script

import Foundation
import AppKit

// MARK: - Configuration

struct GameConfig {
    let appPath: URL
    let winePrefix: URL
    let gameExePath: String
    let gameInstallerDir: String
    let gameEngine: String
    let steamGameId: String?
    let bundleIdForGameTitle: String
    let appSupportPath: URL
}

// MARK: - Plist Reading

func readPlist(at path: URL, key: String) -> String? {
    guard let data = try? Data(contentsOf: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return nil
    }
    
    // Support nested keys using dot notation (e.g., "Parent.Child")
    let keys = key.split(separator: ".").map(String.init)
    var current: Any? = plist
    
    for key in keys {
        guard let dict = current as? [String: Any] else {
            return nil
        }
        current = dict[key]
    }
    
    // Convert result to string
    if let string = current as? String {
        return string
    } else if let number = current as? NSNumber {
        return number.stringValue
    } else if let bool = current as? Bool {
        return bool ? "true" : "false"
    }
    
    return nil
}

func loadConfig() -> GameConfig? {
    // Get app path
    guard let executablePath = ProcessInfo.processInfo.arguments.first else {
        print("ERROR: Could not determine executable path")
        return nil
    }
    
    let executableURL = URL(fileURLWithPath: executablePath)
    let appPath = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    
    let settingsPlistPath = appPath.appendingPathComponent("Contents/Resources/AppSettings.plist")
    let infoPlistPath = appPath.appendingPathComponent("Contents/Info.plist")
    
    // Read plists
    guard let gameExePath = readPlist(at: settingsPlistPath, key: "GameExePath"),
          let gameInstallerDir = readPlist(at: settingsPlistPath, key: "GameInstallerDir"),
          let gameEngine = readPlist(at: settingsPlistPath, key: "GameEngine"),
          let bundleIdForGameTitle = readPlist(at: infoPlistPath, key: "CFBundleIdentifierForGameTitle") else {
        print("ERROR: Could not read required configuration from plists")
        return nil
    }
    
    let steamGameId = readPlist(at: settingsPlistPath, key: "SteamGameId")
    
    let winePrefix = appPath.appendingPathComponent("Contents/SharedSupport/prefix")
    
    // Setup app support directory
    let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(bundleIdForGameTitle)
    
    try? FileManager.default.createDirectory(at: appSupportPath, withIntermediateDirectories: true)
    
    return GameConfig(
        appPath: appPath,
        winePrefix: winePrefix,
        gameExePath: gameExePath,
        gameInstallerDir: gameInstallerDir,
        gameEngine: gameEngine,
        steamGameId: steamGameId,
        bundleIdForGameTitle: bundleIdForGameTitle,
        appSupportPath: appSupportPath
    )
}

// MARK: - Wine Management

func startWineServer(_ config: GameConfig) {
    let wine = WineEnvironment(appPath: config.appPath)
    wine.runExecutable("wineserver", arguments: ["-p"])
}

func stopWineServer(_ config: GameConfig) {
    let wine = WineEnvironment(appPath: config.appPath)
    wine.runExecutable("wineserver", arguments: ["-w"])
}

// MARK: - Directory Mounting

func mountDirectoryIntoWine(_ config: GameConfig, hostPath: URL, driveLetter: String) {
    let dosdevicesPath = config.winePrefix.appendingPathComponent("dosdevices")
    let linkPath = dosdevicesPath.appendingPathComponent("\(driveLetter):")
    
    try? FileManager.default.createDirectory(at: dosdevicesPath, withIntermediateDirectories: true)
    
    // Remove existing link if preexecutable: "wine", args: ["start", 
    try? FileManager.default.removeItem(at: linkPath)
    
    // Create symlink
    try? FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: hostPath)
}

// MARK: - Alert Display

func showAlert(message: String, informativeText: String) {
    // Initialize NSApplication if not already done
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informativeText
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Understood")
    alert.runModal()
}

func showDebugSettings(_ config: GameConfig) -> Bool {
    // Initialize NSApplication if not already done
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    
    let alert = NSAlert()
    alert.messageText = "Debug Settings"
    alert.informativeText = "Game: \(config.appPath.lastPathComponent)\nEngine: \(config.gameEngine)\nPrefix: \(config.winePrefix.path)"
    alert.alertStyle = .informational
    
    alert.addButton(withTitle: "Continue Launch")
    alert.addButton(withTitle: "Open Wine Shell")
    alert.addButton(withTitle: "Cancel")
    
    let response = alert.runModal()
    
    switch response {
    case .alertFirstButtonReturn:  // Continue Launch
        return true
    case .alertSecondButtonReturn:  // Open Wine Shell
        launchWineShell(config)
        return false
    default:  // Cancel
        return false
    }
}

func launchWineShell(_ config: GameConfig) {
    print("Opening Wine shell...")
    
    // Get Wine environment variables
    let wine = WineEnvironment(appPath: config.appPath)
    let envVars = wine.environmentVariables()
    
    // Build export statements for all environment variables
    var exportStatements = ""
    for (key, value) in envVars.sorted(by: { $0.key < $1.key }) {
        // Escape special characters in the value
        let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
        exportStatements += "export \(key)=\"\(escapedValue)\"\n"
    }
    
    // Create a temporary shell script that launches wine cmd
    let tempDir = FileManager.default.temporaryDirectory
    let scriptPath = tempDir.appendingPathComponent("wine-shell-\(UUID().uuidString).command")
    
    let shellScript = """
    #!/bin/bash
    cd "\(config.winePrefix.path)"
    
    # Set Wine environment variables
    \(exportStatements)
    
    # Launch Wine command prompt
    "\(config.appPath.path)/Contents/SharedSupport/wine/bin/wine" cmd
    """
    
    do {
        try shellScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        
        // Open the script in Terminal - this doesn't require Apple Events permission
        NSWorkspace.shared.open(scriptPath)
        
        print("Wine shell opened in Terminal")
    } catch {
        print("ERROR: Failed to create shell script: \(error)")
        showAlert(message: "Failed to Open Shell", informativeText: "Could not create temporary shell script: \(error.localizedDescription)")
    }
}

func launchWineShellInline(_ config: GameConfig) {
    // Change to Wine prefix directory
    FileManager.default.changeCurrentDirectoryPath(config.winePrefix.path)
    
    // Get Wine environment variables
    let wine = WineEnvironment(appPath: config.appPath)
    let envVars = wine.environmentVariables()
    
    // Set up environment
    for (key, value) in envVars {
        setenv(key, value, 1)
    }
    
    // Execute wine cmd, replacing current process
    let winePath = config.appPath.path + "/Contents/SharedSupport/wine/bin/wine"
    let args = ["wine", "cmd"]
    
    // Convert Swift strings to C strings
    let cArgs = args.map { strdup($0) } + [nil]
    
    // Execute wine - this replaces the current process
    execv(winePath, cArgs)
    
    // If execv returns, there was an error
    print("ERROR: Failed to execute Wine shell")
    exit(1)
}

// MARK: - Game Launching

func launchWineGame(_ config: GameConfig) -> Int32 {
    // Build the full Unix path to the game exe
    // gameExePath is relative to C: drive (e.g., "/private/Nancy Drew/Game.exe")
    let gameExePathClean = config.gameExePath.hasPrefix("/") 
        ? String(config.gameExePath.dropFirst()) 
        : config.gameExePath
    
    let gameExeUnixPath = config.winePrefix
        .appendingPathComponent("drive_c")
        .appendingPathComponent(gameExePathClean)
        .path
    
    print("Launching game: \(gameExeUnixPath)")
    
    let wine = WineEnvironment(appPath: config.appPath)
    let wineExecutable = config.appPath.path + "/Contents/SharedSupport/wine/bin/wine"
    let arguments = ["start", "/wait", "/unix", gameExeUnixPath]
    
    // Get Wine-specific environment variables (not all system vars)
    let wineEnvVars = wine.wineSpecificEnvironmentVariables()
    
    // Print export commands for manual use (Wine-specific only)
    print("\nWine-specific environment variables (for manual debugging):")
    print("# These are the custom env vars needed for Wine to work properly")
    for (key, value) in wineEnvVars.sorted(by: { $0.key < $1.key }) {
        let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
        print("export \(key)=\"\(escapedValue)\"")
    }
    print("")
    
    // Print full command
    let fullCommand = "\(wineExecutable) \(arguments.joined(separator: " "))"
    print("Full command: \(fullCommand)")
    
    // Pass the Unix path to wine's start command with /unix flag
    return wine.runExecutable("wine", arguments: arguments)
}

// MARK: - Main

func main() {
    guard let config = loadConfig() else {
        print("ERROR: Failed to load configuration")
        exit(1)
    }
    
    print("Game engine: \(config.gameEngine)")
    
    // Check for --wine-shell flag to launch wine shell directly
    if ProcessInfo.processInfo.arguments.contains("--wine-shell") {
        print("Launching Wine shell in current terminal...")
        launchWineShellInline(config)
        exit(0)
    }
    
    // Check if debug mode should be shown
    // Either via Option key or --debug command line flag
    let optionKeyHeld = NSEvent.modifierFlags.contains(.option)
    let debugFlagProvided = ProcessInfo.processInfo.arguments.contains("--debug")
    
    if optionKeyHeld || debugFlagProvided {
        if optionKeyHeld {
            print("Option key detected - showing debug settings")
        } else {
            print("--debug flag detected - showing debug settings")
        }
        let shouldContinue = showDebugSettings(config)
        if !shouldContinue {
            print("Launch cancelled from debug settings")
            exit(0)
        }
    }
    
    // Show warning alert before starting Wine
    if config.gameEngine == "wine" || config.gameEngine.hasPrefix("wine-steam") {
        var warningMessage = "Crashes may occur, especially if you switch to a different app when the game is running."
        if config.gameEngine.hasPrefix("wine-steam") {
            warningMessage += "\n\nAlso due to the way Steam works it may take a minute or more to launch the game. Sorry for the wait."
        }
        
        showAlert(message: "Save regularly to avoid losing progress", informativeText: warningMessage)
    }
    
    print("Starting game...")
    
    // Setup Wine environment
    // Note: wineserver will be started automatically by wine when needed
    
    // Mount app support directory into Wine
    mountDirectoryIntoWine(config, hostPath: config.appSupportPath, driveLetter: "a")
    
    // Link save directory
    let documentsPath = config.winePrefix.appendingPathComponent("drive_c/users/\(WineEnvironment.wineUsername)/Documents")
    try? FileManager.default.removeItem(at: documentsPath)
    try? FileManager.default.createSymbolicLink(at: documentsPath, withDestinationURL: config.appSupportPath)
    
    // Record game engine on first run
    let gameEngineFile = config.appSupportPath.appendingPathComponent("game-engine")
    if !FileManager.default.fileExists(atPath: gameEngineFile.path) {
        try? config.gameEngine.write(to: gameEngineFile, atomically: true, encoding: .utf8)
    }
    
    // Launch based on engine type
    let exitCode: Int32
    
    switch config.gameEngine {
    case "wine":
        exitCode = launchWineGame(config)
        
    case "wine-steam", "wine-steam-silent":
        print("ERROR: Steam engine not yet implemented in Swift runtime")
        print("Please use the bash runtime for Steam games")
        exit(1)
        
    case "scummvm":
        exitCode = launchScummVMGame(config)
        
    default:
        print("ERROR: Unknown game engine: \(config.gameEngine)")
        exit(1)
    }
    
    print("Game exited with code: \(exitCode)")
    print("Quitting...")
}

// MARK: - ScummVM Launching

func launchScummVMGame(_ config: GameConfig) -> Int32 {
    // Get paths
    let resourcesPath = config.appPath.appendingPathComponent("Contents/Resources")
    let scummvmBinary = resourcesPath.appendingPathComponent("scummvm/Resources/scummvm").path
    let scummvmIni = resourcesPath.appendingPathComponent("scummvm/Resources/scummvm.ini").path
    let gamePath = config.appPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c\(config.gameInstallerDir)").path
    let savePath = config.appSupportPath.path
    let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(config.bundleIdForGameTitle).ini").path
    
    print("ScummVM binary: \(scummvmBinary)")
    print("ScummVM ini: \(scummvmIni)")
    print("Game path: \(gamePath)")
    print("Save path: \(savePath)")
    print("Config path: \(configPath)")
    
    // Build ScummVM arguments
    // We don't use ScummVM's autorun system since it's more convenient to set game path here
    // but for more info see: https://docs.scummvm.org/en/latest/advanced_topics/autostart.html
    let arguments = [
        "-f",                           // Fullscreen
        "--config=\(configPath)",       // User config file location
        "--initial-cfg=\(scummvmIni)",  // Initial configuration
        "--path=\(gamePath)",           // Game files location
        "--savepath=\(savePath)",       // Save files location
        "--auto-detect"                 // Automatically detect and start game
    ]
    
    print("Launching ScummVM with arguments:")
    for arg in arguments {
        print("  \(arg)")
    }
    
    // Print full command
    let fullCommand = "\(scummvmBinary) \(arguments.joined(separator: " "))"
    print("Full command: \(fullCommand)")
    
    // Execute ScummVM
    let task = Process()
    task.executableURL = URL(fileURLWithPath: scummvmBinary)
    task.arguments = arguments
    
    // Capture output
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
        
        // Print output
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), !output.isEmpty {
            print("ScummVM output:")
            print(output)
        }
        
        return task.terminationStatus
    } catch {
        print("ERROR: Failed to launch ScummVM: \(error.localizedDescription)")
        return 1
    }
}

// Run the main function
main()
