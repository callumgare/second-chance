//
//  NancyDrewQuitScenario.swift
//  WrappPuppeteer
//
//  Launch a Nancy Drew wrapp, get it to the main menu, and quit through the
//  game's own Exit button — proving the game starts and responds to input.

import Foundation
import AppKit
import CoreGraphics
import Logging

struct NancyDrewQuitScenario {
    struct Options {
        /// How long to wait for the game's window once its process is up.
        var windowDetectTimeout: TimeInterval = 30
        /// How long to wait for the game's process to appear. A Wine wrapp
        /// waits up to 60 s for Wine's desktop before it starts the game
        /// (`GameLauncher.prepareDesktop`), so this has to outlast that.
        var processDetectTimeout: TimeInterval = 90
        var infoWindowTimeout: TimeInterval = 15
        var quitTimeout: TimeInterval = 90
        /// How long to keep looking for the Exit button
        var findExitTimeout: TimeInterval = 60
        /// Only logged — nothing enforces it yet.
        var maxRuntime: TimeInterval = 60
        /// Launch the wrapp with `--debug`
        var debugMode = false
    }

    let wrapp: Wrapp
    let options: Options
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.NancyDrewQuitScenario")

    func run() -> PuppetResult {
        logger.notice("🎮 Starting Nancy Drew quit scenario")
        logger.notice("   App: \(wrapp.appPath)")
        logger.notice("   Engine: \(wrapp.engineSetting)")
        logger.notice("   Executable: \(wrapp.gameExeName)")
        if wrapp.engine == .wine {
            logger.notice("   Wine prefix: \(wrapp.winePrefix.path)")
        }
        logger.notice("   Max runtime: \(Int(options.maxRuntime))s")

        ProcessCleanup.install(pkillArguments: wrapp.engine.helperPkillArguments)

        guard let app = ProcessControl.launch(appPath: wrapp.appPath, arguments: options.debugMode ? ["--debug"] : []) else {
            return .failed("Failed to launch game")
        }
        ProcessCleanup.track(appPid: app.processIdentifier, helperPid: nil)

        let appName = app.localizedName ?? "WrappTemplate"
        logger.notice("ℹ️  Game process: \(appName) (PID: \(app.processIdentifier))")

        if wrapp.engine == .wine {
            logger.notice("ℹ️  Wine game - checking for info window...")
            Thread.sleep(forTimeInterval: 1)
            guard InfoWindow.dismiss(wrapperPid: app.processIdentifier, timeout: options.infoWindowTimeout) else {
                forceQuit(app)
                return .failed("Failed to dismiss info window")
            }
        }

        guard let gamePid = waitForGameWindow() else {
            forceQuit(app)
            return .failed("Game process or window did not appear in time")
        }

        logger.notice("ℹ️  Game process PID: \(gamePid)")
        ProcessCleanup.track(appPid: app.processIdentifier, helperPid: gamePid)

        guard clickExit(appName: appName, app: app, gamePid: gamePid) else {
            return .failed("OCR could not find Exit button")
        }

        logger.notice("⏳ Waiting for game to exit...")
        if ProcessControl.waitForTermination(app, helperPid: gamePid, timeout: options.quitTimeout) {
            logger.notice("✅ Game exited cleanly")
            return .passed
        }

        logger.warning("⚠️  Game did not exit cleanly, force quitting...")
        forceQuit(app)
        Thread.sleep(forTimeInterval: 2)
        if app.isTerminated {
            logger.notice("✅ Game force-quit successful")
            return .forcedQuit
        }
        return .failed("Failed to quit game even after force-quit")
    }

    // MARK: - Private

    private var focusStrategy: FocusStrategy { wrapp.engine.focusStrategy }

    private var backingScaleFactor: CGFloat { NSScreen.main?.backingScaleFactor ?? 1.0 }

    /// The centre of a rect found in a screenshot, which is in pixels, as the
    /// screen point a click needs.
    private func screenPoint(atCentreOf rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX / backingScaleFactor, y: rect.midY / backingScaleFactor)
    }

    private func forceQuit(_ app: NSRunningApplication) {
        ProcessControl.forceQuit(app, pkillArguments: wrapp.engine.helperPkillArguments)
    }

    /// Wait for the game's process, then its window, then for it to take
    /// focus. Returns the game process's PID.
    private func waitForGameWindow() -> Int32? {
        let processName = wrapp.engine.gameProcessName(gameExeName: wrapp.gameExeName)
        logger.notice("⏳ Waiting for game process (timeout: \(Int(options.processDetectTimeout))s), then its window...")
        let start = Date()

        logger.notice("[Step 1] Monitoring for \(processName) process...")
        guard let process = ProcessFinder.waitForProcess(named: processName, timeout: options.processDetectTimeout) else {
            return nil
        }
        let pid = process.pid

        logger.notice("[Step 2] Monitoring for windows from \(processName) (PID: \(pid))...")
        guard let windows = WindowFinder.waitForWindows(timeout: options.windowDetectTimeout, where: { $0.ownerPid == pid }) else {
            logger.critical("❌ Timeout: \(processName) process found but no windows appeared")
            WindowFinder.logAllWindows()
            return nil
        }

        logger.notice("✅ Game window detected after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        for (index, window) in windows.enumerated() {
            logger.notice("   [\(index + 1)] \(window.title) - \(Int(window.bounds.width))x\(Int(window.bounds.height))")
        }

        logger.notice("[Step 3] Waiting for game to become active...")
        guard FocusDetector.waitForFocus(pid: pid, strategy: focusStrategy, activate: wrapp.engine.activatesForFocus) else {
            return nil
        }

        NSSound.beep()

        // Screenshots of what was detected, for diagnosing later failures
        if let path = ScreenCapture.captureWindow(number: windows[0].number, prefix: "game-window-detected") {
            logger.notice("📸 Window screenshot: \(path)")
        }
        if let path = ScreenCapture.captureScreen(prefix: "game-fullscreen-detected") {
            logger.notice("📸 Full screen screenshot: \(path)")
        }

        return pid
    }

    /// Look for the Exit button and click it, clicking the Her Interactive
    /// logo first if the game is still on its splash screen. True once Exit
    /// has been clicked and the game lost focus or exited.
    private func clickExit(appName: String, app: NSRunningApplication, gamePid: Int32) -> Bool {
        logger.notice("🎮 Attempting to quit game...")

        var clickedInteractive = false
        var clickedExitButton = false
        let startTime = Date()
        var attempt = 0

        while Date().timeIntervalSince(startTime) < options.findExitTimeout {
            attempt += 1
            let iterationStartTime = Date()

            if attempt == 1 { NSSound.beep() }

            // Losing focus after clicking Exit means the game is shutting down;
            // losing it before means something else took over the screen.
            guard FocusDetector.isFocused(pid: gamePid, strategy: focusStrategy) else {
                if clickedExitButton { return true }
                forceQuit(app)
                return false
            }

            logger.notice("  → Attempt \(attempt) (elapsed: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)")

            guard let screenshotPath = ScreenCapture.captureScreen(prefix: "game-test") else { continue }

            let searchStartTime = Date()
            let analysis = MainMenuScreen.analyze(screenshotPath: screenshotPath, app: app)
            logger.notice("    ⏱️  Search took \(String(format: "%.2f", Date().timeIntervalSince(searchStartTime)))s")
            try? FileManager.default.removeItem(atPath: screenshotPath)

            if let exitLocation = analysis.quitButton {
                guard FocusDetector.isFocused(pid: gamePid, strategy: focusStrategy) else {
                    if clickedExitButton { return true }
                    forceQuit(app)
                    return false
                }

                logger.notice(clickedExitButton ? "  ✓ Clicking 'Exit Game' button again..." : "  ✓ Found 'Exit Game' button, clicking...")
                clickedExitButton = true

                var clickPoint = screenPoint(atCentreOf: exitLocation)

                // The Scarlet Hand's Exit hotspot sits above its label
                if appName.contains("Scarlet Hand") {
                    clickPoint.y -= exitLocation.height / (2.0 * backingScaleFactor)
                }

                InputControl.click(at: clickPoint)
                Thread.sleep(forTimeInterval: 1)

                // The game draws its own cursor into the frame, so left on the
                // button it hides part of the label from OCR (or hover-
                // highlights it) and a retry can't find it. Park it against the
                // left edge, clear of the centred menu text and of the
                // bottom-right corner the quit-button template is searched in.
                // Not on the edge itself, which would reveal a left-hand Dock.
                let screenFrame = NSScreen.main?.frame ?? .zero
                InputControl.moveMouse(to: CGPoint(x: screenFrame.minX + 20, y: screenFrame.midY))

                if !ProcessControl.isRunning(app, helperPid: gamePid) {
                    logger.notice("✅ Game exited successfully")
                    return true
                }
            }

            if let interactiveLocation = analysis.interactiveLogo, !clickedInteractive {
                logger.notice("  ✓ Found 'interactive' logo, clicking to enable menu...")
                Thread.sleep(forTimeInterval: 1)
                InputControl.click(at: screenPoint(atCentreOf: interactiveLocation))
                clickedInteractive = true
                Thread.sleep(forTimeInterval: 2)
            }

            let remainingTime = 0.2 - Date().timeIntervalSince(iterationStartTime)
            if remainingTime > 0 { Thread.sleep(forTimeInterval: remainingTime) }
        }

        forceQuit(app)
        return false
    }
}
