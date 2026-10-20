//
//  WindowFinder.swift
//  WrappPuppeteer
//
//  On-screen window listing via CGWindowList.

import Foundation
import AppKit
import CoreGraphics
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.WindowFinder")

/// One entry from `CGWindowListCopyWindowInfo`, typed.
struct WindowInfo {
    let number: Int32
    let ownerPid: Int32
    let ownerName: String
    let title: String
    /// Global display coordinates, top-left origin, in points.
    let bounds: CGRect

    init?(_ dictionary: [String: Any]) {
        guard let pid = dictionary[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        let rawBounds = dictionary[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        ownerPid = pid
        number = dictionary[kCGWindowNumber as String] as? Int32 ?? 0
        ownerName = dictionary[kCGWindowOwnerName as String] as? String ?? "(no owner)"
        title = dictionary[kCGWindowName as String] as? String ?? "(unnamed)"
        bounds = CGRect(x: rawBounds["X"] ?? 0, y: rawBounds["Y"] ?? 0, width: rawBounds["Width"] ?? 0, height: rawBounds["Height"] ?? 0)
    }

    /// Ignores menu-bar extras, cursors and other tiny helper windows.
    var isSubstantial: Bool { bounds.width > 50 && bounds.height > 50 }

    var area: CGFloat { bounds.width * bounds.height }
}

enum WindowFinder {
    static func onScreenWindows(excludingDesktop: Bool = true) -> [WindowInfo] {
        var options: CGWindowListOption = [.optionOnScreenOnly]
        if excludingDesktop { options.insert(.excludeDesktopElements) }
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { WindowInfo($0) }
    }

    /// `pid`'s biggest on-screen window: an app's own, rather than the
    /// helper windows beside it. Look it up each time it's needed, since an
    /// app can replace its window (Wine does as a game goes fullscreen).
    static func mainWindow(ofPid pid: Int32) -> WindowInfo? {
        onScreenWindows().filter { $0.ownerPid == pid && $0.isSubstantial }.max { $0.area < $1.area }
    }

    /// Poll until at least one on-screen window matches, returning all matches.
    static func waitForWindows(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        where matches: (WindowInfo) -> Bool
    ) -> [WindowInfo]? {
        let start = Date()
        var lastLog = Date.distantPast
        while Date().timeIntervalSince(start) < timeout {
            let found = onScreenWindows().filter(matches)
            if !found.isEmpty { return found }

            if Date().timeIntervalSince(lastLog) >= 5 {
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] No matching windows yet, still waiting...")
                lastLog = Date()
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }

    /// Every active display's bounds, in the same coordinates as `WindowInfo.bounds`.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Whether `window` covers a whole display — what a fullscreen window
    /// does, whether it is in its own Space or drawn borderless over the
    /// menu bar. A maximised window still leaves the menu bar showing.
    static func isFullScreen(_ window: WindowInfo, displays: [CGRect] = displayBounds()) -> Bool {
        displays.contains { display in
            abs(window.bounds.minX - display.minX) <= 1 && abs(window.bounds.minY - display.minY) <= 1
                && abs(window.bounds.width - display.width) <= 1 && abs(window.bounds.height - display.height) <= 1
        }
    }

    /// Poll until one of `pid`'s on-screen windows covers a whole display.
    /// Waits rather than checks once: going fullscreen is animated, and a
    /// window may be put into fullscreen only once it has settled.
    static func waitForFullScreenWindow(pid: Int32, timeout: TimeInterval, pollInterval: TimeInterval = 0.5) -> WindowInfo? {
        let start = Date()
        var lastLog = Date.distantPast
        while Date().timeIntervalSince(start) < timeout {
            let displays = displayBounds()
            let windows = onScreenWindows().filter { $0.ownerPid == pid && $0.isSubstantial }
            if let window = windows.first(where: { isFullScreen($0, displays: displays) }) { return window }
            // On a display with a camera notch, macOS puts a native
            // fullscreen window below the notch's strip, so its bounds never
            // match the display's (and the strip's height is in no API).
            // Ask the window instead.
            if Accessibility.hasFullscreenWindow(pid: pid),
               let window = windows.max(by: { $0.area < $1.area }) {
                return window
            }

            if Date().timeIntervalSince(lastLog) >= 5 {
                let sizes = windows.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height)) at (\(Int($0.bounds.minX)),\(Int($0.bounds.minY)))" }
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] No fullscreen window yet (windows: \(sizes.joined(separator: ", ")); displays: \(displays.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ", ")))")
                lastLog = Date()
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }

    /// Log every substantial on-screen window, for diagnosing a failed wait.
    static func logAllWindows() {
        logger.notice("📋 Current windows on screen:")
        for (index, window) in onScreenWindows().enumerated() where window.isSubstantial {
            logger.notice("   [\(index)] Owner: '\(window.ownerName)' (PID \(window.ownerPid)) | Title: '\(window.title)' | Size: \(Int(window.bounds.width))x\(Int(window.bounds.height))")
        }
    }
}
