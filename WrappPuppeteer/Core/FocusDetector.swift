//
//  FocusDetector.swift
//  WrappPuppeteer
//
//  Deciding whether the app under test is the one receiving input.

import Foundation
import AppKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.FocusDetector")

/// How to tell that an app is in front. Apps differ: some never report
/// `isActive` reliably, others take over the screen without activating.
enum FocusStrategy {
    /// `isActive`, or the frontmost application's PID matches.
    case frontmost
    /// One of the app's windows is in native full screen.
    case fullscreenWindow
}

enum FocusDetector {
    static func isFocused(pid: Int32, strategy: FocusStrategy) -> Bool {
        switch strategy {
        case .fullscreenWindow:
            return Accessibility.hasFullscreenWindow(pid: pid)
        case .frontmost:
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
                return false
            }
            return app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
    }

    /// Wait for the app to be focused, re-activating it on each attempt when
    /// `activate` is set. Once focused, waits `settleDelay` more so the window
    /// has finished drawing before anything inspects it.
    static func waitForFocus(
        pid: Int32,
        strategy: FocusStrategy,
        activate: Bool,
        timeout: TimeInterval = 10,
        settleDelay: TimeInterval = 10
    ) -> Bool {
        logger.notice("⏳ Waiting for PID \(pid) to become focused...")
        let start = Date()
        var lastLog = Date()

        while Date().timeIntervalSince(start) < timeout {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] PID \(pid) not found in running applications...")
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }

            if activate {
                _ = app.activate(options: [.activateAllWindows])
            }
            Thread.sleep(forTimeInterval: 0.2)

            if isFocused(pid: pid, strategy: strategy) {
                Thread.sleep(forTimeInterval: settleDelay)
                logger.notice("✅ Focused after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return true
            }

            if Date().timeIntervalSince(lastLog) >= 2 {
                let frontmost = NSWorkspace.shared.frontmostApplication
                let frontmostName = frontmost?.localizedName ?? frontmost?.bundleIdentifier ?? "unknown"
                logger.notice("   [\(String(format: "%.1f", Date().timeIntervalSince(start)))s] Not focused yet — frontmost is \(frontmostName) (PID \(frontmost?.processIdentifier ?? -1))")
                lastLog = Date()
            }

            Thread.sleep(forTimeInterval: 0.3)
        }

        logger.critical("❌ Timeout: PID \(pid) did not become focused within \(Int(timeout))s")
        return false
    }
}
