//
//  Accessibility.swift
//  WrappPuppeteer
//
//  Thin helpers over the AXUIElement API, for windows that expose an
//  accessibility tree (native AppKit/SwiftUI — not Wine or ScummVM content).

import Foundation
import AppKit
import ApplicationServices
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.Accessibility")

/// An `AXError` as a Swift `Error`, so it can travel in a `Result`.
struct AccessibilityError: Error {
    let code: AXError
}

enum Accessibility {
    /// The app's accessible windows. A window that has only just appeared can
    /// report `.cannotComplete`, so that error is retried.
    static func windows(ofPid pid: Int32, retries: Int = 5, retryDelay: TimeInterval = 0.5) -> Result<[AXUIElement], AccessibilityError> {
        let app = AXUIElementCreateApplication(pid)
        var attempt = 0
        while true {
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .success {
                guard let windows = windowsRef as? [AXUIElement] else { return .failure(AccessibilityError(code: .failure)) }
                return .success(windows)
            }
            attempt += 1
            guard result == .cannotComplete, attempt < retries else { return .failure(AccessibilityError(code: result)) }
            logger.notice("  → Window not accessible yet, retrying (\(attempt)/\(retries))...")
            Thread.sleep(forTimeInterval: retryDelay)
        }
    }

    static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        return ref as? String
    }

    static func title(of element: AXUIElement) -> String? {
        string(kAXTitleAttribute, of: element)
    }

    /// Depth-first search for a button whose title, description, value or
    /// identifier contains any of `searchTerms`. SwiftUI buttons may expose
    /// their label through any of those, so all are checked.
    static func findButton(in element: AXUIElement, containing searchTerms: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 20 else { return nil }

        if string(kAXRoleAttribute, of: element) == kAXButtonRole as String {
            let candidates = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXIdentifier"]
                .compactMap { string($0, of: element) }
                .filter { !$0.isEmpty }
            if candidates.isEmpty {
                logger.debug("Found button with no title/desc/value/identifier")
            }
            for text in candidates where searchTerms.contains(where: { text.contains($0) }) {
                logger.notice("  ✓ Found button: '\(text)'")
                return element
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let button = findButton(in: child, containing: searchTerms, depth: depth + 1) {
                return button
            }
        }
        return nil
    }

    /// The element's frame in global display coordinates (top-left origin).
    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        // The type IDs were checked above, so these casts cannot fail.
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// True when any of the app's windows is in native full screen.
    static func hasFullscreenWindow(pid: Int32) -> Bool {
        guard case .success(let windows) = Accessibility.windows(ofPid: pid, retries: 1) else { return false }
        return windows.contains { window in
            var ref: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &ref) == .success && (ref as? Bool) == true
        }
    }

    /// Log an AXError with troubleshooting for the permission case.
    static func logFailure(_ error: AXError) {
        logger.critical("   AXError code: \(error.rawValue) (\(describe(error)))")
        if error == .apiDisabled {
            logger.notice("   Troubleshooting:")
            logger.notice("   1. Open System Settings → Privacy & Security → Accessibility")
            logger.notice("   2. Ensure WrappPuppeteer has Accessibility permission")
            logger.notice("   3. Try relaunching WrappPuppeteer after granting permission")
        }
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "Success"
        case .failure: return "Failure"
        case .illegalArgument: return "Illegal Argument"
        case .invalidUIElement: return "Invalid UI Element"
        case .invalidUIElementObserver: return "Invalid UI Element Observer"
        case .cannotComplete: return "Cannot Complete"
        case .attributeUnsupported: return "Attribute Unsupported"
        case .actionUnsupported: return "Action Unsupported"
        case .notificationUnsupported: return "Notification Unsupported"
        case .notImplemented: return "Not Implemented"
        case .notificationAlreadyRegistered: return "Notification Already Registered"
        case .notificationNotRegistered: return "Notification Not Registered"
        case .apiDisabled: return "API Disabled (accessibility not enabled)"
        case .noValue: return "No Value"
        case .parameterizedAttributeUnsupported: return "Parameterized Attribute Unsupported"
        case .notEnoughPrecision: return "Not Enough Precision"
        @unknown default: return "Unknown"
        }
    }
}
