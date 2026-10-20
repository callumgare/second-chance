#!/usr/bin/env swift

import Foundation
import CoreGraphics
import AppKit
import ImageIO
import Logging

// Bootstrap logging before anything else can construct a Logger — top-level
// code in main.swift runs in source order, and the logger below (like any
// earlier Logger construction) must resolve its handler after this call.
AppLogging.bootstrap(subsystem: "au.gare.callum.second-chance.WrappPuppeteer")

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.main")
RunContext.logHeader(logger)

func printUsage() {
    logger.notice("""
    WrappPuppeteer - drives a Nancy Drew wrapp from launch to quit

    Usage:
        WrappPuppeteer <app-path> [options]
        WrappPuppeteer --analyze <screenshot-path>
        WrappPuppeteer --classify <game-slug> <frame.png|dir>...
        WrappPuppeteer --make-splash-reference <frame.png> <out.png>

    Options:
        --timeout <seconds>    Maximum runtime (default: 60)
        --debug                Launch the wrapp in debug mode
        --parent-pid <pid>     Stop, killing the wrapp, once this process exits
        --analyze <path>       Analyze a screenshot for quit buttons (no launch)
        --record <dir>         Save the game window to <dir> from when it appears
                               until the run ends
        --record-seconds <s>   Click nothing: record for <s> seconds, then quit
        --classify             Print each frame's nearest splash screen of the game
                               and how near it is (no launch)
        --make-splash-reference
                               Save a frame's picture, bars trimmed, as a splash
                               reference image (no launch)
        --help                 Show this help

    Exit codes:
        0   App exited cleanly
        2   App required force-quit (acceptable — some Wine games need this)
        1   Test failed (launch failure, OCR failure, etc.)
    """)
}

var appPath: String?
var options = NancyDrewQuitScenario.Options()
var analyzePath: String?
var classifyArguments: [String]?
var splashReferenceArguments: [String]?

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
    case "--parent-pid":
        i += 1
        if i < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[i]) {
            ProcessCleanup.watchParent(pid)
        }
    case "--record":
        i += 1
        if i < CommandLine.arguments.count {
            options.recordDirectory = URL(fileURLWithPath: CommandLine.arguments[i])
        }
    case "--record-seconds":
        i += 1
        if i < CommandLine.arguments.count, let seconds = TimeInterval(CommandLine.arguments[i]) {
            options.watchOnlySeconds = seconds
        }
    case "--classify":
        classifyArguments = Array(CommandLine.arguments.dropFirst(i + 1))
        i = CommandLine.arguments.count
    case "--make-splash-reference":
        splashReferenceArguments = Array(CommandLine.arguments.dropFirst(i + 1))
        i = CommandLine.arguments.count
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

// --classify mode: which of a game's splash screens each frame is closest to
if let arguments = classifyArguments {
    guard arguments.count >= 2 else {
        fputs("Usage: --classify <game-slug> <frame.png|dir>...\n", stderr)
        exit(1)
    }
    let screens = SplashScreen.screens(forGame: arguments[0])
    if screens.isEmpty { fputs("No splash references for \(arguments[0])\n", stderr) }
    var frames: [String] = []
    for argument in arguments.dropFirst() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory), isDirectory.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: argument)) ?? []
            frames += files.filter { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") }.sorted()
                .map { (argument as NSString).appendingPathComponent($0) }
        } else {
            frames.append(argument)
        }
    }
    for frame in frames {
        let name = (frame as NSString).lastPathComponent
        guard let fingerprint = ImageFingerprint(imageAt: frame) else {
            print("\(name)\tblank")
            continue
        }
        guard let nearest = SplashScreen.closest(fingerprint, among: screens) else {
            print("\(name)\t-")
            continue
        }
        let verdict = nearest.distance <= SplashScreen.matchDistance ? "SPLASH" : "-"
        print("\(name)\t\(verdict)\t\(nearest.screen.name)\t\(String(format: "%.3f", nearest.distance))")
    }
    exit(0)
}

// --make-splash-reference mode: a frame's picture as a splash reference
if let arguments = splashReferenceArguments {
    guard arguments.count == 2,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[0]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fputs("Usage: --make-splash-reference <frame.png> <out.png>\n", stderr)
        exit(1)
    }
    guard let content = ImageFingerprint.content(of: image, width: 160),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, "public.png" as CFString, 1, nil) else {
        fputs("\(arguments[0]) is blank\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(destination, content, nil)
    exit(CGImageDestinationFinalize(destination) ? 0 : 1)
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

// No permissions to ask for: the wrapp and the game capture and click their
// own windows for us (InProcessControl). An accessory app (no Dock icon),
// because macOS keeps a regular app's windows out of another app's
// fullscreen Space, so the click animation would never show over a
// fullscreen game.
NSApplication.shared.setActivationPolicy(.accessory)

let scenario = NancyDrewQuitScenario(wrapp: Wrapp(appPath: path), options: options)
let result = scenario.run()
switch result {
case .passed:
    logger.notice("WRAPP_PUPPETEER: run_succeeded")
case .failed(let reason):
    // The integration test quotes this in its failure, so the reason reads
    // there and not only in the attached log.
    logger.error("WRAPP_PUPPETEER: run_failed: \(reason)")
case .forcedQuit:
    break
}
LogStore.shared.flush()
exit(result.exitCode)
