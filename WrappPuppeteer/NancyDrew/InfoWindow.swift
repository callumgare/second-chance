//
//  InfoWindow.swift
//  WrappPuppeteer
//
//  The "save regularly" warning a Wine wrapp shows before starting the game,
//  and the loading window it becomes. The wrapp answers for it on wrapp.sock
//  (WrappTemplate/PuppetServer.swift): `info` and `confirm`.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.InfoWindow")

enum InfoWindow {
    struct Info {
        let open: Bool
        let warning: Bool
    }

    static func info(_ wrapp: ControlSocket) -> Info? {
        guard let fields = ControlSocket.fields(of: wrapp.request("info", timeout: 10)) else { return nil }
        return Info(open: fields["open"] == "1", warning: fields["warning"] == "1")
    }

    /// Wait for the save warning and confirm it. False if it never showed, or
    /// was still showing after several tries.
    static func dismiss(wrapp: ControlSocket, timeout: TimeInterval) -> Bool {
        logger.notice("🔍 Waiting for the wrapp's save warning...")
        let deadline = Date().addingTimeInterval(timeout)
        while info(wrapp)?.warning != true {
            if Date() >= deadline {
                logger.critical("❌ The save warning didn't show within \(Int(timeout))s (wrapp says: \(wrapp.request("info", timeout: 10) ?? "nothing — is its socket up?"))")
                return false
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        logger.notice("  → Save warning showing")

        for attempt in 1...5 {
            let reply = wrapp.request("confirm") ?? "no reply"
            logger.notice("  ✓ Confirming it: \(reply)")
            if reply == "ok pressed" {
                logger.warning("⚠️  The click on I Understand didn't take; the wrapp confirmed the warning directly")
            }
            if waitForWarningToGo(wrapp, timeout: 10) {
                logger.notice("✅ Save warning dismissed")
                return true
            }
            logger.warning("⚠️  Save warning still showing (attempt \(attempt))")
        }
        logger.critical("❌ Save warning still showing after confirming it five times")
        return false
    }

    /// Wait for the window to close, which the wrapp does once the game's
    /// window is up. False if it is still open at `timeout` — the wrapp then
    /// missed the game starting, and leaves "Loading…" up until the game exits.
    static func waitForClose(wrapp: ControlSocket, timeout: TimeInterval) -> Bool {
        logger.notice("🔍 Checking the wrapp's info window has closed...")
        let start = Date()
        while info(wrapp)?.open != false {
            if Date().timeIntervalSince(start) >= timeout {
                logger.critical("❌ Info window still open \(Int(timeout))s after the game's window appeared")
                return false
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        logger.notice("✅ Info window closed after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        return true
    }

    private static func waitForWarningToGo(_ wrapp: ControlSocket, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if info(wrapp)?.warning == false { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }
}
