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
nonisolated public struct WindowInfo {
    public let number: Int32
    public let ownerPid: Int32
    public let ownerName: String
    /// "(unnamed)" unless WrappPuppeteer has Screen Recording, which it
    /// doesn't need — so for logs only, never to find a window by.
    public let title: String
    /// Global display coordinates, top-left origin, in points.
    public let bounds: CGRect
    /// The window's level: 0 for an app's ordinary windows, above it the
    /// Dock, Notification Centre and the menu bar, below it the desktop's.
    public let layer: Int
    /// 0 for a window that's there but can't be seen.
    public let alpha: Double

    public init?(_ dictionary: [String: Any]) {
        guard let pid = dictionary[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        let rawBounds = dictionary[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        ownerPid = pid
        number = dictionary[kCGWindowNumber as String] as? Int32 ?? 0
        ownerName = dictionary[kCGWindowOwnerName as String] as? String ?? "(no owner)"
        title = dictionary[kCGWindowName as String] as? String ?? "(unnamed)"
        bounds = CGRect(x: rawBounds["X"] ?? 0, y: rawBounds["Y"] ?? 0, width: rawBounds["Width"] ?? 0, height: rawBounds["Height"] ?? 0)
        layer = dictionary[kCGWindowLayer as String] as? Int ?? 0
        alpha = dictionary[kCGWindowAlpha as String] as? Double ?? 1
    }

    public init(number: Int32, ownerPid: Int32, ownerName: String, bounds: CGRect, layer: Int = 0, alpha: Double = 1) {
        self.number = number
        self.ownerPid = ownerPid
        self.ownerName = ownerName
        title = "(unnamed)"
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }

    /// Ignores menu-bar extras, cursors and other tiny helper windows.
    public var isSubstantial: Bool { bounds.width > 50 && bounds.height > 50 }

    public var area: CGFloat { bounds.width * bounds.height }
}

nonisolated public enum WindowFinder {
    public static func onScreenWindows(excludingDesktop: Bool = true) -> [WindowInfo] {
        var options: CGWindowListOption = [.optionOnScreenOnly]
        if excludingDesktop { options.insert(.excludeDesktopElements) }
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { WindowInfo($0) }
    }

    /// The app whose window is in front of every other app's: the first
    /// ordinary (layer 0), visible, substantial window in the window server's
    /// front-to-back order. Asked of the window server each time, so it's
    /// current even in a process whose main thread never turns its run loop,
    /// where AppKit's `isActive` and `frontmostApplication` stay as they
    /// were when last refreshed. Nil when no app has such a window.
    public static func frontOwner(of windows: [WindowInfo]) -> Int32? {
        frontWindow(of: windows)?.ownerPid
    }

    /// The window `frontOwner` goes by.
    public static func frontWindow(of windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.layer == 0 && $0.alpha > 0 && $0.isSubstantial }
    }

    /// What's in front, for a log: the owner of the front window, else
    /// AppKit's frontmost application.
    public static func describeFront() -> String {
        if let front = frontWindow(of: onScreenWindows()) {
            return "\(front.ownerName) (PID \(front.ownerPid))"
        }
        let app = NSWorkspace.shared.frontmostApplication
        return "\(app?.localizedName ?? app?.bundleIdentifier ?? "nothing") (PID \(app?.processIdentifier ?? -1))"
    }

    /// `pid`'s biggest on-screen window: an app's own, rather than the
    /// helper windows beside it. Look it up each time it's needed, since an
    /// app can replace its window (Wine does as a game goes fullscreen).
    public static func mainWindow(ofPid pid: Int32) -> WindowInfo? {
        onScreenWindows().filter { $0.ownerPid == pid && $0.isSubstantial }.max { $0.area < $1.area }
    }

    /// Poll until at least one on-screen window matches, returning all matches.
    /// Gives up early, returning nil, once `giveUp` says there's no point
    /// waiting on (the process that would own the window has exited, say).
    public static func waitForWindows(
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
    public static func logAllWindows() {
        logger.notice("📋 Current windows on screen:")
        for (index, window) in onScreenWindows().enumerated() where window.isSubstantial {
            let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
            logger.notice("   [\(index)] Owner: '\(window.ownerName)' (PID \(window.ownerPid)) | Title: '\(window.title)' | Size: \(size)")
        }
    }
}
