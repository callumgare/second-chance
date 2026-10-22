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
    /// "(unnamed)" unless WrappPuppeteer has Screen Recording, which it
    /// doesn't need — so for logs only, never to find a window by.
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
    /// Gives up early, returning nil, once `giveUp` says there's no point
    /// waiting on (the process that would own the window has exited, say).
    static func waitForWindows(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        where matches: (WindowInfo) -> Bool,
        giveUp: () -> Bool = { false }
    ) -> [WindowInfo]? {
        let start = Date()
        var lastLog = Date.distantPast
        while Date().timeIntervalSince(start) < timeout {
            let found = onScreenWindows().filter(matches)
            if !found.isEmpty { return found }
            if giveUp() { return nil }

            if Date().timeIntervalSince(lastLog) >= 5 {
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] No matching windows yet, still waiting...")
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
            let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
            logger.notice("   [\(index)] Owner: '\(window.ownerName)' (PID \(window.ownerPid)) | Title: '\(window.title)' | Size: \(size)")
        }
    }
}
