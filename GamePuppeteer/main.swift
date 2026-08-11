#!/usr/bin/env swift

import Foundation
import os

private let logger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "main")

func printUsage() {
    logger.notice("""
    GamePuppeteer - Automated game launch & quit test tool

    Usage:
        GamePuppeteer <app-path> [options]

    Options:
        --timeout <seconds>    Maximum runtime (default: 60)
        --debug                Launch game in debug mode
        --help                 Show this help

    Exit codes:
        0   Game exited cleanly
        2   Game required force-quit (acceptable — some Wine games need this)
        1   Test failed (launch failure, OCR failure, etc.)
        3   Accessibility permission not granted
        4   Screen Recording permission not granted
        5   Screen Recording was manually confirmed; relaunch required
    """)
}

var appPath: String?
var timeout: TimeInterval = 60
var debugMode = false

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
    default:
        if appPath == nil && !arg.hasPrefix("-") {
            appPath = arg
        }
    }

    i += 1
}

guard let path = appPath else {
    logger.fault("Error: No app path provided")
    printUsage()
    exit(1)
}

if !StartupPermissions.ensureAccessibilityPermission() {
    exit(GamePuppetExitCode.permissionDeniedAccessibility.rawValue)
}

switch StartupPermissions.ensureScreenRecordingPermission() {
case .granted:
    break
case .denied:
    exit(GamePuppetExitCode.permissionDeniedScreenRecording.rawValue)
case .relaunchRequired:
    exit(GamePuppetExitCode.permissionRelaunchRequiredScreenRecording.rawValue)
}

logger.notice("PERMISSION_GATE: all_permissions_granted")

StartupPermissions.warmupPrivilegedAPIs()

logger.notice("  → Installing signal handlers...")
signal(SIGINT, handleTermination)
signal(SIGTERM, handleTermination)
signal(SIGHUP, handleTermination)
logger.notice("  → Signal handlers installed")

let gameEngine = readGameEngine(appPath: path) ?? "unknown"
let gameExePath = readGameExePath(appPath: path) ?? "/Game.exe"
let gameExeName = (gameExePath as NSString).lastPathComponent
let winePrefix = getWinePrefix(appPath: path)

logger.notice("ℹ️  Game engine: \(gameEngine, privacy: .public)")
logger.notice("ℹ️  Game executable: \(gameExeName, privacy: .public)")
if gameEngine.lowercased().contains("wine") {
    logger.notice("ℹ️  Wine prefix: \(winePrefix.path, privacy: .public)")
}

let config = TestConfig(
    appPath: path,
    maxRuntime: timeout,
    gameEngine: gameEngine,
    debugMode: debugMode
)

let session = GamePuppetSession(config: config, gameExeName: gameExeName, winePrefix: winePrefix)
let result = session.run()
if result.exitCode == GamePuppetExitCode.passed.rawValue {
    logger.notice("GAME_PUPPETEER: run_succeeded")
}
exit(result.exitCode)
