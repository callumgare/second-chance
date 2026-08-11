//
//  Permissions.swift
//  GamePuppeteer
//
//  Centralized permission checks and prompts used by startup gating.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os

private let permissionLogger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "Permissions")

enum PermissionWaitOutcome {
    case granted
    case timedOut
    case manualConfirmationRequested
}

enum ScreenRecordingPermissionResult {
    case granted
    case denied
    case relaunchRequired
}

enum StartupPermissions {
    private static let defaultPermissionWaitTimeout: TimeInterval = 120
    private static let permissionPollInterval: TimeInterval = 1

    static func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        permissionLogger.error("⚠️  Accessibility permission required")
        permissionLogger.notice("PERMISSION_GATE: permission_requested accessibility")
        permissionLogger.notice("Waiting for Accessibility permission to be granted...")

        let waitingWindow = PermissionWaitWindowController(
            permissionName: "Accessibility",
            instructions: "Enable GamePuppeteer in System Settings > Privacy & Security > Accessibility",
            manualConfirmationRequired: false,
            systemSettingsAnchor: "Privacy_Accessibility"
        )
        waitingWindow.show()
        defer { waitingWindow.close() }

        let waitOutcome = waitForPermissionGrant(
            permissionName: "Accessibility",
            checkPermission: { AXIsProcessTrusted() },
            waitingWindow: waitingWindow
        )

        let granted = waitOutcome == .granted

        if !granted {
            permissionLogger.error("Accessibility permission was not granted before timeout")
            permissionLogger.error("Go to System Settings -> Privacy & Security -> Accessibility")
        }

        return granted
    }

    static func ensureScreenRecordingPermission() -> ScreenRecordingPermissionResult {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }

        permissionLogger.error("⚠️  Screen Recording permission required")
        permissionLogger.notice("PERMISSION_GATE: permission_requested screen_recording")
        permissionLogger.notice("Requesting Screen Recording permission for GamePuppeteer...")

        // CGRequestScreenCaptureAccess triggers the system prompt for this process.
        if CGRequestScreenCaptureAccess() {
            return .granted
        }

        permissionLogger.notice("Use 'Open System Settings' to grant permission...")

        let waitingWindow = PermissionWaitWindowController(
            permissionName: "Screen Recording",
            instructions: "Enable GamePuppeteer in System Settings > Privacy & Security > Screen Recording",
            manualConfirmationRequired: true,
            systemSettingsAnchor: "Privacy_ScreenCapture"
        )
        waitingWindow.show()
        defer { waitingWindow.close() }

        permissionLogger.notice("Please:")
        permissionLogger.notice("  1. Find and enable GamePuppeteer in the list")
        permissionLogger.notice("  2. Click the lock icon and authenticate if needed")
        permissionLogger.notice("  3. Approve the prompt, then wait for detection to continue")

        let waitOutcome = waitForPermissionGrant(
            permissionName: "Screen Recording",
            checkPermission: { CGPreflightScreenCaptureAccess() },
            waitingWindow: waitingWindow
        )

        if waitOutcome == .manualConfirmationRequested {
            permissionLogger.notice("Manual confirmation received; requesting relaunch to re-check Screen Recording permission")
            return .relaunchRequired
        }

        if waitOutcome != .granted {
            permissionLogger.error("Screen Recording permission was not granted before timeout")
            permissionLogger.error("If just granted, macOS may still require a relaunch before APIs update")
            return .denied
        }

        return .granted
    }

    static func warmupPrivilegedAPIs() {
        // Trigger a harmless first-use path early so permission state is settled
        // before game automation starts.
        _ = canReadWindowMetadata()
    }

    private static func canReadWindowMetadata() -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

        // If we can inspect non-system window names, screen capture metadata access is likely available.
        var namedWindowCount = 0
        var totalWindowCount = 0

        for window in windowList {
            let windowName = window[kCGWindowName as String] as? String ?? ""
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""

            if !ownerName.isEmpty && ownerName != "Window Server" && ownerName != "Dock" {
                totalWindowCount += 1
                if !windowName.isEmpty {
                    namedWindowCount += 1
                }
            }
        }

        return totalWindowCount == 0 || namedWindowCount > 0
    }

    private static func waitForPermissionGrant(
        permissionName: String,
        checkPermission: () -> Bool,
        waitingWindow: PermissionWaitWindowController
    ) -> PermissionWaitOutcome {
        // When manual confirmation is required (Screen Recording), we intentionally
        // do not poll for in-process permission changes. Some macOS versions only
        // apply that grant after relaunch, so the user confirms completion explicitly.
        if waitingWindow.requiresManualConfirmation {
            return waitingWindow.waitForManualConfirmation(timeout: permissionWaitTimeout())
                ? .manualConfirmationRequested
                : .timedOut
        }

        let timeout = permissionWaitTimeout()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if waitingWindow.didRequestManualConfirmation {
                permissionLogger.notice("User manually confirmed \(permissionName, privacy: .public) permission update")
                return .manualConfirmationRequested
            }

            if checkPermission() {
                permissionLogger.notice("\(permissionName, privacy: .public) permission granted")
                return .granted
            }
            waitingWindow.pumpUIEvents(until: Date().addingTimeInterval(permissionPollInterval))
        }

        permissionLogger.error("Timed out waiting \(String(format: "%.0f", timeout), privacy: .public)s for \(permissionName, privacy: .public) permission")
        return .timedOut
    }

    private static func permissionWaitTimeout() -> TimeInterval {
        let env = Foundation.ProcessInfo.processInfo.environment["GAME_PUPPETEER_PERMISSION_WAIT_SECONDS"]
        guard let env, let parsed = TimeInterval(env), parsed > 0 else {
            return defaultPermissionWaitTimeout
        }
        return parsed
    }

}
