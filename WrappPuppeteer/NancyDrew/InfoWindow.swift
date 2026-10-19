//
//  InfoWindow.swift
//  WrappPuppeteer
//
//  The "save regularly" warning a Wine wrapp shows before starting the game.

import Foundation
import AppKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.InfoWindow")

enum InfoWindow {
    /// Native SwiftUI window, titled after the series.
    private static let title = "Nancy Drew"
    /// Its confirm button: the accessibility identifier first, then labels.
    private static let confirmButtonTerms = ["save-regularly-warning-confirm", "Understand", "OK", "Continue"]

    /// Find the wrapp's info window and click its confirm button.
    static func dismiss(wrapperPid: Int32, timeout: TimeInterval) -> Bool {
        logger.notice("🔍 Looking for wrapper info window from PID \(wrapperPid)...")

        // The info window is around 450 wide and 200–300 tall, which tells it
        // apart from other windows the wrapp might have open.
        let found = WindowFinder.waitForWindows(timeout: timeout, pollInterval: 0.3) { window in
            window.ownerPid == wrapperPid
                && window.title == title
                && (400..<500).contains(window.bounds.width)
                && (50..<400).contains(window.bounds.height)
        }
        guard let window = found?.first else {
            logger.notice("  → Info window not found (may have been auto-dismissed)")
            WindowFinder.logAllWindows()
            return false
        }

        logger.notice("  → Found info window: \(Int(window.bounds.width))x\(Int(window.bounds.height))")

        // Give the window a moment to finish initialising its AX tree
        Thread.sleep(forTimeInterval: 0.5)

        let axWindows: [AXUIElement]
        switch Accessibility.windows(ofPid: wrapperPid) {
        case .success(let windows):
            axWindows = windows
        case .failure(let error):
            logger.critical("❌ Could not access info window via Accessibility API")
            Accessibility.logFailure(error.code)
            return false
        }

        guard let axWindow = axWindows.first(where: { Accessibility.title(of: $0)?.contains(title) == true }) else {
            logger.critical("❌ Info window is on screen but not in the Accessibility tree")
            logger.critical("   Accessible window titles: \(axWindows.map { Accessibility.title(of: $0) ?? "(no title)" })")
            return false
        }

        guard let button = Accessibility.findButton(in: axWindow, containing: confirmButtonTerms) else {
            // SwiftUI hosted views may not expose their buttons. Pressing
            // Return would activate the default button, but it is disabled
            // here — this path carries on as if the window were dismissed.
            logger.warning("⚠️  Confirm button not found via Accessibility — continuing without dismissing")
            // InputControl.pressReturn()
            Thread.sleep(forTimeInterval: 0.5)
            return true
        }

        guard let frame = Accessibility.frame(of: button) else {
            logger.critical("❌ Confirm button has no readable position/size")
            return false
        }

        let clickPoint = CGPoint(x: frame.midX, y: frame.midY)
        logger.notice("  ✓ Clicking confirm button at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
        InputControl.click(at: clickPoint)

        // A click can be lost on a loaded machine (the wrapp then sat on this
        // window for the whole test), so check the warning went, and if it
        // didn't, press the button through Accessibility instead. The window
        // itself stays up after a confirm, showing a loading message until
        // the game has loaded, so what goes is the confirm button.
        for attempt in 1...5 {
            if waitForWarningToGo(wrapperPid: wrapperPid, timeout: 10) {
                logger.notice("✅ Info window dismissed")
                return true
            }
            logger.warning("⚠️  Info window still open — pressing its confirm button through Accessibility (attempt \(attempt))")
            let result = Accessibility.press(button)
            if result != .success {
                logger.warning("   AXPress failed: \(Accessibility.describe(result))")
            }
        }
        logger.critical("❌ Info window still open after clicking and pressing its confirm button")
        return false
    }

    /// Wait for the window to close, which the wrapp does once the game's
    /// window is up. False if it is still open at `timeout` — the wrapp then
    /// missed the game starting, and leaves "Loading…" up until the game exits.
    static func waitForClose(wrapperPid: Int32, timeout: TimeInterval) -> Bool {
        logger.notice("🔍 Checking the wrapp's info window has closed...")
        let start = Date()
        while isOpen(wrapperPid: wrapperPid) {
            if Date().timeIntervalSince(start) >= timeout {
                logger.critical("❌ Info window still open \(Int(timeout))s after the game's window appeared")
                WindowFinder.logAllWindows()
                if let path = ScreenCapture.captureScreen(prefix: "info-window-still-open") {
                    logger.notice("📸 Full screen screenshot: \(path)")
                }
                return false
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        logger.notice("✅ Info window closed after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        return true
    }

    /// Whether the window is open. Asks Accessibility as well as the on-screen
    /// window list, since a full-screen game puts the window on another Space,
    /// where the list no longer counts it as on screen.
    private static func isOpen(wrapperPid: Int32) -> Bool {
        if WindowFinder.onScreenWindows().contains(where: { $0.ownerPid == wrapperPid && $0.title == title }) {
            return true
        }
        guard case .success(let windows) = Accessibility.windows(ofPid: wrapperPid, retries: 1) else { return false }
        // Exact match: in debug mode the wrapp also has a "… - Launch Log" window.
        return windows.contains { Accessibility.title(of: $0) == title }
    }

    /// True once the window has closed or no longer shows its confirm button.
    private static func waitForWarningToGo(wrapperPid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let open = WindowFinder.onScreenWindows().contains { $0.ownerPid == wrapperPid && $0.title == title }
            if !open || !showsConfirmButton(wrapperPid: wrapperPid) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private static func showsConfirmButton(wrapperPid: Int32) -> Bool {
        guard case .success(let windows) = Accessibility.windows(ofPid: wrapperPid, retries: 1),
              let axWindow = windows.first(where: { Accessibility.title(of: $0)?.contains(title) == true }) else {
            // Can't tell; keep waiting rather than call it gone.
            return true
        }
        return Accessibility.findButton(in: axWindow, containing: confirmButtonTerms) != nil
    }
}
