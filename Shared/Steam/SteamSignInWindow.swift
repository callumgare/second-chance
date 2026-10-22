//
//  SteamSignInWindow.swift
//  Shared
//
//  Brings Steam's sign-in window to the front once Steam asks for a sign-in.
//  Getting there can take many minutes (Steam installs and updates itself
//  first), and the player has usually gone to another app by then, so the
//  window would otherwise open behind it. See docs/steam.md.

import AppKit
import CoreGraphics
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")

nonisolated enum SteamSignInWindow {
    /// The programs whose windows are Steam's: the client, and the web
    /// helper that draws its UI.
    static let processNames: Set<String> = ["steam.exe", "steamwebhelper.exe"]

    /// Wait up to `timeout` for a window of Steam's to be on screen, then
    /// bring it to the front. Only one wrapp or build runs Steam at a time
    /// (`SteamActiveLock`), so any Steam window on screen is this one's.
    /// Returns whether it found one to bring forward. `window` names it in
    /// the log.
    @discardableResult
    static func bringForward(timeout: TimeInterval = 60, window: String = "sign-in window") async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let pid = steamWindowOwner() {
                let activated = await activate(pid: pid)
                if activated {
                    logger.notice("Brought Steam's \(window) to the front")
                } else {
                    logger.warning("Couldn't bring Steam's \(window) to the front (pid \(pid)); macOS refused the activation")
                }
                return activated
            }
            guard Date() < deadline else {
                logger.warning("None of Steam's windows appeared within \(Int(timeout))s to bring its \(window) forward")
                return false
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The process owning Steam's largest on-screen window, if any.
    static func steamWindowOwner() -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (pid: pid_t, area: CGFloat)?
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
            // Skips the tiny helper windows Wine and CEF keep about.
            guard area > 200 * 200, area > (best?.area ?? 0),
                  let name = ProcessName.executable(ofPID: pid),
                  processNames.contains(name.lowercased()) else { continue }
            best = (pid, area)
        }
        return best?.pid
    }

    /// Activate `pid`'s app with all its windows. Since macOS 14 activation
    /// is cooperative: only the active app can pass it on, by yielding. By
    /// the time Steam asks for a sign-in the player has usually gone to
    /// another app, and then macOS refuses outright. So when it does, this
    /// app first activates itself through Launch Services — the way `open`
    /// brings an app forward, which macOS allows — and then yields to Steam.
    private static func activate(pid: pid_t) async -> Bool {
        if await MainActor.run(body: { handOver(to: pid) }) { return true }
        logger.notice("Steam's sign-in window couldn't be brought forward directly; activating this app first")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } catch {
            logger.warning("Couldn't activate this app to hand over to Steam: \(error.localizedDescription)")
            return false
        }
        // Activation lands a moment after Launch Services returns.
        for _ in 0..<20 where !(await MainActor.run { NSApp?.isActive ?? false }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await MainActor.run { handOver(to: pid) }
    }

    /// Yield to `pid`'s app and activate it; true when it's then active or on
    /// its way (macOS returns false when it refuses).
    @MainActor
    private static func handOver(to pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        NSApp?.yieldActivation(to: app)
        return app.activate(options: [.activateAllWindows])
    }
}
