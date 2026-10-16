#!/usr/bin/env swift

import Foundation
import CoreGraphics
import Logging

// Bootstrap logging before anything else can construct a Logger — top-level
// code in main.swift runs in source order, and the logger below (like any
// earlier Logger construction) must resolve its handler after this call.
AppLogging.bootstrap(subsystem: "au.gare.callum.second-chance.WrappPuppeteer")

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.main")

func printUsage() {
    logger.notice("""
    WrappPuppeteer - drives a Nancy Drew wrapp from launch to quit

    Usage:
        WrappPuppeteer <app-path> [options]
        WrappPuppeteer --analyze <screenshot-path>

    Options:
        --timeout <seconds>    Maximum runtime (default: 60)
        --debug                Launch the wrapp in debug mode
        --analyze <path>       Analyze a screenshot for quit buttons (no launch)
        --help                 Show this help

    Exit codes:
        0   App exited cleanly
        2   App required force-quit (acceptable — some Wine games need this)
        1   Test failed (launch failure, OCR failure, etc.)
        3   Accessibility permission not granted
        4   Screen Recording permission not granted
        5   Screen Recording was manually confirmed; relaunch required
    """)
}

var appPath: String?
var options = NancyDrewQuitScenario.Options()
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
            options.maxRuntime = TimeInterval(CommandLine.arguments[i]) ?? 60
        }
    case "--debug":
        options.debugMode = true
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
    let result = MainMenuScreen.analyze(screenshotPath: screenshotPath)
    // Human-readable summary on stdout, for use from a terminal
    print("Screenshot analysis: \(screenshotPath)")
    if let r = result.quitButton { print("  Quit button: x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))") }
    if let r = result.interactiveLogo { print("  Interactive logo: x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))") }
    if result.quitButton == nil && result.interactiveLogo == nil {
        print("  (nothing found)")
    }
    exit(0)
}

guard let path = appPath else {
    logger.critical("Error: No app path provided")
    printUsage()
    exit(1)
}

if !StartupPermissions.ensureAccessibilityPermission() {
    exit(PuppetExitCode.permissionDeniedAccessibility.rawValue)
}

switch StartupPermissions.ensureScreenRecordingPermission() {
case .granted:
    break
case .denied:
    exit(PuppetExitCode.permissionDeniedScreenRecording.rawValue)
case .relaunchRequired:
    exit(PuppetExitCode.permissionRelaunchRequiredScreenRecording.rawValue)
}

logger.notice("PERMISSION_GATE: all_permissions_granted")

StartupPermissions.warmupPrivilegedAPIs()

let scenario = NancyDrewQuitScenario(wrapp: Wrapp(appPath: path), options: options)
let result = scenario.run()
if result.exitCode == PuppetExitCode.passed.rawValue {
    logger.notice("WRAPP_PUPPETEER: run_succeeded")
}
LogStore.shared.flush()
exit(result.exitCode)
