#!/usr/bin/env swift

import Foundation
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "main")

func printUsage() {
    logger.notice("""
    GamePuppeteer - Automated game launch & quit test tool

    Usage:
        GamePuppeteer <app-path> [options]
        GamePuppeteer --analyze <screenshot-path> [--quit-image <path>]

    Options:
        --timeout <seconds>    Maximum runtime (default: 60)
        --debug                Launch game in debug mode
        --verbose, -v          Stream logs to the console
        --analyze <path>       Analyze a screenshot for quit buttons (no game launch)
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
var verbose = false
var analyzePath: String?

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
    case "--verbose", "-v":
        verbose = true
    case "--analyze":
        i += 1
        if i < CommandLine.arguments.count {
            analyzePath = CommandLine.arguments[i]
        }
    default:
        if appPath == nil && !arg.hasPrefix("-") {
            appPath = arg
        }
    }

    i += 1
}

// --analyze mode: run screen analysis against a saved screenshot and exit
if let screenshotPath = analyzePath {
    guard FileManager.default.fileExists(atPath: screenshotPath) else {
        fputs("Error: Screenshot not found at \(screenshotPath)\n", stderr)
        exit(1)
    }
    let result = analyzeScreenshot(at: screenshotPath)
    // Print human-readable summary to stdout
    print("Screenshot analysis: \(screenshotPath)")
    if let r = result.quitButton { print("  Quit button: x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))") }
    if let r = result.interactiveLogo { print("  Interactive logo: x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))") }
    if result.quitButton == nil && result.interactiveLogo == nil {
        print("  (nothing found)")
    }
    exit(0)
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

// Stream os.Logger output to stderr so logs are visible in the terminal
var logStreamProcess: Process?
if verbose {
    let pid = getpid()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    proc.arguments = ["stream", "--process", "\(pid)", "--style", "compact",
                      "--predicate", "subsystem == \"com.secondchance.gamepuppeteer\""]
    proc.standardOutput = FileHandle.standardError
    try? proc.run()
    logStreamProcess = proc
    // Give log stream a moment to attach
    Thread.sleep(forTimeInterval: 0.3)
}

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
logStreamProcess?.terminate()
exit(result.exitCode)
