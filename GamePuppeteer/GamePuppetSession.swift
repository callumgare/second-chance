import Foundation
import AppKit
import CoreGraphics
import os

/// Orchestrates a single game launch-and-quit session. Encapsulates the
/// logic previously in GameTester's free functions into a testable struct.
struct GamePuppetSession {
    let config: TestConfig
    let gameExeName: String
    let winePrefix: URL
    private let logger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "GamePuppetSession")

    func run() -> GamePuppetResult {
        logger.notice("🎮 Starting puppet session")
        logger.notice("   App: \(config.appPath, privacy: .public)")
        logger.notice("   Engine: \(config.gameEngine, privacy: .public)")
        logger.notice("   Executable: \(gameExeName, privacy: .public)")
        logger.notice("   Max runtime: \(Int(config.maxRuntime), privacy: .public)s")

        var arguments: [String] = []
        if config.debugMode { arguments.append("--debug") }

        guard let app = ProcessManager.launch(appPath: config.appPath, arguments: arguments) else {
            return .failed("Failed to launch game")
        }

        let appName = app.localizedName ?? "GameWrapper"
        logger.notice("ℹ️  Game process: \(appName, privacy: .public) (PID: \(app.processIdentifier, privacy: .public))")

        if config.gameEngine.lowercased().contains("wine") {
            logger.error("⚠️  Wine game detected - checking for info window...")
            Thread.sleep(forTimeInterval: 1)
            guard InfoWindowHandler.dismissInfoWindow(wrapperPid: Int32(app.processIdentifier), config: config) else {
                ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
                return .failed("Failed to dismiss info window")
            }
        }

        guard let gamePid = WindowDetector.waitForWindow(
            appName: appName,
            wrapperPid: Int32(app.processIdentifier),
            gameEngine: config.gameEngine,
            gameExeName: gameExeName,
            prefixPath: winePrefix,
            timeout: config.windowDetectTimeout
        ) else {
            ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
            return .failed("Game window did not appear within \(Int(config.windowDetectTimeout))s")
        }

        logger.notice("ℹ️  Game process PID: \(gamePid, privacy: .public)")
        SignalHandler.setup(app: app, gamePid: gamePid)

        let ocrSuccess = attemptQuit(appName: appName, app: app, gamePid: gamePid)

        if !ocrSuccess {
            return .failed("OCR could not find Exit button")
        }

        logger.notice("⏳ Waiting for game to exit...")
        if ProcessManager.waitForTermination(app, gamePid: gamePid, timeout: config.quitTimeout) {
            logger.notice("✅ Game exited cleanly")
            return .passed
        } else {
            logger.error("⚠️  Game did not exit cleanly, force quitting...")
            ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
            Thread.sleep(forTimeInterval: 2)
            if app.isTerminated {
                logger.notice("✅ Game force-quit successful")
                return .forcedQuit
            } else {
                return .failed("Failed to quit game even after force-quit")
            }
        }
    }

    // MARK: - Private

    private func attemptQuit(appName: String, app: NSRunningApplication, gamePid: Int32?) -> Bool {
        logger.notice("🎮 Attempting to quit game...")

        var clickedInteractive = false
        var clickedExitButton = false
        let quitTimeout: TimeInterval = 60
        let startTime = Date()
        var attempt = 0

        while Date().timeIntervalSince(startTime) < quitTimeout {
            attempt += 1
            let iterationStartTime = Date()

            if attempt == 1 { NSSound.beep() }

            guard let pid = gamePid else {
                logger.error("⚠️  No game PID available, cannot check focus")
                break
            }

            if !GameFocusDetector.isGameFocused(pid: pid, gameEngine: config.gameEngine) {
                if clickedExitButton {
                    return true
                } else {
                    ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
                    return false
                }
            }

            logger.notice("  → Attempt \(attempt, privacy: .public) (elapsed: \(String(format: "%.1f", Date().timeIntervalSince(startTime)), privacy: .public)s)")

            guard let screenshotPath = ScreenshotOCR.captureScreen() else { continue }

            let searchStartTime = Date()
            let analysis = analyzeScreenshot(at: screenshotPath, app: app)
            logger.notice("    ⏱️  Search took \(String(format: "%.2f", Date().timeIntervalSince(searchStartTime)), privacy: .public)s")
            try? FileManager.default.removeItem(atPath: screenshotPath)

            let exitLocation = analysis.quitButton

            if let exitLocation = exitLocation {
                guard GameFocusDetector.isGameFocused(pid: pid, gameEngine: config.gameEngine) else {
                    if clickedExitButton { return true }
                    ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
                    return false
                }

                if !clickedExitButton {
                    logger.notice("  ✓ Found 'Exit Game' button, clicking...")
                    clickedExitButton = true
                    if attempt == 1 { NSSound.beep() }
                } else {
                    logger.notice("  ✓ Clicking 'Exit Game' button again...")
                }

                let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
                var clickPoint = CGPoint(
                    x: exitLocation.midX / backingScaleFactor,
                    y: exitLocation.midY / backingScaleFactor
                )

                if appName.contains("Scarlet Hand") {
                    let shiftAmount = exitLocation.height / (2.0 * backingScaleFactor)
                    clickPoint.y -= shiftAmount
                }

                InputControl.click(at: clickPoint)
                Thread.sleep(forTimeInterval: 1)

                let cornerPoint = CGPoint(x: (NSScreen.main?.frame.maxX ?? 0) - 10,
                                          y: (NSScreen.main?.frame.maxY ?? 0) - 10)
                CGWarpMouseCursorPosition(cornerPoint)

                if !ProcessManager.isRunning(app, gamePid: gamePid) {
                    logger.notice("✅ Game exited successfully")
                    return true
                }
            }

            if let interactiveLocation = analysis.interactiveLogo, !clickedInteractive {
                logger.notice("  ✓ Found 'interactive' button, clicking to enable menu...")
                Thread.sleep(forTimeInterval: 1)
                InputControl.click(at: CGPoint(x: interactiveLocation.midX, y: interactiveLocation.midY))
                clickedInteractive = true
                Thread.sleep(forTimeInterval: 2)
            }

            let iterationDuration = Date().timeIntervalSince(iterationStartTime)
            let remainingTime = max(0, 0.2 - iterationDuration)
            if remainingTime > 0 { Thread.sleep(forTimeInterval: remainingTime) }
        }

        ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
        return false
    }
}
