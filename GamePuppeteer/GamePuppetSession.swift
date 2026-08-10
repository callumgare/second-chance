import Foundation
import AppKit
import CoreGraphics

/// Orchestrates a single game launch-and-quit session. Encapsulates the
/// logic previously in GameTester's free functions into a testable struct.
struct GamePuppetSession {
    let config: TestConfig
    let gameExeName: String
    let winePrefix: URL

    // Path to the quit button image, relative to the executable.
    private var quitButtonImagePath: String {
        let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return scriptDir.appendingPathComponent("assets/quit-button.png").path
    }

    func run() -> GamePuppetResult {
        print("🎮 Starting puppet session")
        print("   App: \(config.appPath)")
        print("   Engine: \(config.gameEngine)")
        print("   Executable: \(gameExeName)")
        print("   Max runtime: \(Int(config.maxRuntime))s")
        print("")

        guard WindowDetector.checkScreenRecordingPermission() else {
            return .failed("Screen Recording permission not granted")
        }

        var arguments: [String] = []
        if config.debugMode { arguments.append("--debug") }
        if let logPath = config.logFilePath {
            arguments.append("--game-log-path")
            arguments.append(logPath)
        }

        guard let app = ProcessManager.launch(appPath: config.appPath, arguments: arguments) else {
            return .failed("Failed to launch game")
        }

        let appName = app.localizedName ?? "GameWrapper"
        print("ℹ️  Game process: \(appName) (PID: \(app.processIdentifier))")

        if config.gameEngine.lowercased().contains("wine") {
            print("\n⚠️  Wine game detected - checking for info window...")
            Thread.sleep(forTimeInterval: 1)
            guard InfoWindowHandler.dismissInfoWindow(wrapperPid: Int32(app.processIdentifier), config: config) else {
                ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
                return .failed("Failed to dismiss info window")
            }
            print("")
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

        print("ℹ️  Game process PID: \(gamePid)")
        SignalHandler.setup(app: app, gamePid: gamePid)

        let ocrSuccess = attemptQuit(appName: appName, app: app, gamePid: gamePid)

        if !ocrSuccess {
            return .failed("OCR could not find Exit button")
        }

        print("⏳ Waiting for game to exit...")
        if ProcessManager.waitForTermination(app, gamePid: gamePid, timeout: config.quitTimeout) {
            print("✅ Game exited cleanly")
            return .passed
        } else {
            print("⚠️  Game did not exit cleanly, force quitting...")
            ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
            Thread.sleep(forTimeInterval: 2)
            if app.isTerminated {
                print("✅ Game force-quit successful")
                return .forcedQuit
            } else {
                return .failed("Failed to quit game even after force-quit")
            }
        }
    }

    // MARK: - Private

    private func attemptQuit(appName: String, app: NSRunningApplication, gamePid: Int32?) -> Bool {
        print("🎮 Attempting to quit game...")

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
                print("⚠️  No game PID available, cannot check focus")
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

            print("\n\u{001B}[1m  → Attempt \(attempt)\u{001B}[0m (elapsed: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)")

            guard let screenshotPath = ScreenshotOCR.captureScreen() else { continue }

            let searchStartTime = Date()
            let dispatchGroup = DispatchGroup()
            var foundTexts: [String: CGRect] = [:]
            var quitButtonLocation: CGRect?

            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                foundTexts = ScreenshotOCR.findText(["Exit Game", "Quit", "interactive"], in: screenshotPath, app: app)
                dispatchGroup.leave()
            }

            if FileManager.default.fileExists(atPath: quitButtonImagePath) {
                dispatchGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    quitButtonLocation = ScreenshotOCR.findImage(quitButtonImagePath, in: screenshotPath)
                    dispatchGroup.leave()
                }
            }

            dispatchGroup.wait()
            print("    ⏱️  Search took \(String(format: "%.2f", Date().timeIntervalSince(searchStartTime)))s")
            try? FileManager.default.removeItem(atPath: screenshotPath)

            let exitLocation = foundTexts["Exit Game"] ?? foundTexts["Quit"] ?? quitButtonLocation

            if let exitLocation = exitLocation {
                guard GameFocusDetector.isGameFocused(pid: pid, gameEngine: config.gameEngine) else {
                    if clickedExitButton { return true }
                    ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
                    return false
                }

                if !clickedExitButton {
                    print("  ✓ Found 'Exit Game' button, clicking...")
                    clickedExitButton = true
                    if attempt == 1 { NSSound.beep() }
                } else {
                    print("  ✓ Clicking 'Exit Game' button again...")
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
                    print("✅ Game exited successfully")
                    return true
                }
            }

            if let interactiveLocation = foundTexts["interactive"], !clickedInteractive {
                print("  ✓ Found 'interactive' button, clicking to enable menu...")
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
