#!/usr/bin/env swift

import Foundation
import AppKit
import ApplicationServices

// MARK: - Main

func printUsage() {
    print("""
    GameTester - Automated game testing tool
    
    Usage:
        GameTester <app-path> [options]
    
    Options:
        --timeout <seconds>    Maximum runtime (default: 60)
        --debug                Launch game in debug mode
        --log <path>           Path to write game wrapper log output
        --help                 Show this help
    
    Examples:
        GameTester "/Applications/Nancy Drew.app"
        GameTester "/path/to/Game.app" --timeout 90
        GameTester "/path/to/Game.app" --debug
        GameTester "/path/to/Game.app" --log "/tmp/wrapper.log"
    """)
}

// Check for Accessibility permissions
func checkAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    
    if !trusted {
        print("⚠️  Warning: Accessibility permissions not granted")
        print("   Go to System Settings → Privacy & Security → Accessibility")
        print("   and enable permissions for Terminal or your IDE")
        print("")
    }
    
    return trusted
}

// Parse arguments
var appPath: String?
var timeout: TimeInterval = 60
var debugMode = false
var logFilePath: String?

var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    
    switch arg {
    case "--help", "-h":
        printUsage()
        exit(0)
    case "--timeout":
        i += 1
        if i < CommandLine.arguments.count {
            timeout = TimeInterval(CommandLine.arguments[i]) ?? 60
        }
    case "--debug":
        debugMode = true
    case "--log":
        i += 1
        if i < CommandLine.arguments.count {
            logFilePath = CommandLine.arguments[i]
        }
    default:
        if appPath == nil && !arg.hasPrefix("-") {
            appPath = arg
        }
    }
    
    i += 1
}

guard let path = appPath else {
    print("Error: No app path provided\n")
    printUsage()
    exit(1)
}

// Check accessibility permissions
_ = checkAccessibilityPermissions()

// Install signal handlers early (before launching game)
print("  → Installing signal handlers...")
signal(SIGINT, handleTermination)
signal(SIGTERM, handleTermination)
signal(SIGHUP, handleTermination)
print("  → Signal handlers installed\n")

// Read game engine from plist
let gameEngine = readGameEngine(appPath: path) ?? "unknown"

// Get game executable name from plist
let gameExePath = readGameExePath(appPath: path) ?? "/Game.exe"
let gameExeName = (gameExePath as NSString).lastPathComponent
let winePrefix = getWinePrefix(appPath: path)

print("ℹ️  Game engine: \(gameEngine)")
print("ℹ️  Game executable: \(gameExeName)")
if gameEngine.lowercased().contains("wine") {
    print("ℹ️  Wine prefix: \(winePrefix.path)")
}
print("")

// Run test
let config = TestConfig(appPath: path, maxRuntime: timeout, gameEngine: gameEngine, debugMode: debugMode, logFilePath: logFilePath)
let exitCode = runTest(config: config, gameExeName: gameExeName, winePrefix: winePrefix)

exit(exitCode)
