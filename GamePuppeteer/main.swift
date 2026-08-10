#!/usr/bin/env swift

import Foundation
import ApplicationServices

func printUsage() {
    print("""
    GamePuppeteer - Automated game launch & quit test tool

    Usage:
        GamePuppeteer <app-path> [options]

    Options:
        --timeout <seconds>    Maximum runtime (default: 60)
        --debug                Launch game in debug mode
        --game-log-path <path>      Path to write game wrapper log output
        --puppeteer-log-path <path> Path to write GamePuppeteer's own stdout/stderr
        --help                 Show this help

    Exit codes:
        0   Game exited cleanly
        2   Game required force-quit (acceptable — some Wine games need this)
        1   Test failed (launch failure, OCR failure, etc.)
    """)
}

func checkAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

    if !trusted {
        print("⚠️  Warning: Accessibility permissions not granted")
        print("   Go to System Settings → Privacy & Security → Accessibility")
    }

    return trusted
}

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
    case "--game-log-path":
        i += 1
        if i < CommandLine.arguments.count {
            logFilePath = CommandLine.arguments[i]
        }
    case "--puppeteer-log-path":
        i += 1
        if i < CommandLine.arguments.count {
            // Redirect stdout+stderr to a file so the test runner can attach them.
            let fd = open(CommandLine.arguments[i], O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 { dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); close(fd) }
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

_ = checkAccessibilityPermissions()

print("  → Installing signal handlers...")
signal(SIGINT, handleTermination)
signal(SIGTERM, handleTermination)
signal(SIGHUP, handleTermination)
print("  → Signal handlers installed\n")

let gameEngine = readGameEngine(appPath: path) ?? "unknown"
let gameExePath = readGameExePath(appPath: path) ?? "/Game.exe"
let gameExeName = (gameExePath as NSString).lastPathComponent
let winePrefix = getWinePrefix(appPath: path)

print("ℹ️  Game engine: \(gameEngine)")
print("ℹ️  Game executable: \(gameExeName)")
if gameEngine.lowercased().contains("wine") {
    print("ℹ️  Wine prefix: \(winePrefix.path)")
}
print("")

let config = TestConfig(
    appPath: path,
    maxRuntime: timeout,
    gameEngine: gameEngine,
    debugMode: debugMode,
    logFilePath: logFilePath
)

let session = GamePuppetSession(config: config, gameExeName: gameExeName, winePrefix: winePrefix)
exit(session.run().exitCode)
