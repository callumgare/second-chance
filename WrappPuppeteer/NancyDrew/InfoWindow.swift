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
            logger.error("⚠️  Confirm button not found via Accessibility — continuing without dismissing")
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
        Thread.sleep(forTimeInterval: 0.5)

        logger.notice("✅ Info window dismissed")
        return true
    }
}
