//
//  WindowManagement.swift
//  GameTester
//
//  Window detection, focus management, and accessibility handling

import Foundation
import AppKit
import CoreGraphics
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.GamePuppeteer.WindowManagement")

// MARK: - Info Window Handler

enum InfoWindowHandler {
    /// Recursively search for a button with a title containing any of the search terms
    static func findButton(in element: AXUIElement, containing searchTerms: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 20 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String
        
        // Collect all text attributes — SwiftUI buttons may expose their label via any of these
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""
        
        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = descRef as? String ?? ""
        
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let value = valueRef as? String ?? ""

        var identifierRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identifierRef)
        let identifier = identifierRef as? String ?? ""
        
        // Check if this is a button with matching text in any attribute
        if role == kAXButtonRole as String {
            let candidates = [title, desc, value, identifier].filter { !$0.isEmpty }
            if candidates.isEmpty {
                logger.notice("  [DEBUG]     Found button with no title/desc/value/identifier")
            }
            for text in candidates {
                for term in searchTerms {
                    if text.lowercased().contains(term.lowercased()) {
                        logger.notice("  [DEBUG]     ✓ Found button: '\(text)'")
                        return element
                    }
                }
            }
        }
        
        // Recursively search children
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        
        if childrenResult == .success, let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let button = findButton(in: child, containing: searchTerms, depth: depth + 1) {
                    return button
                }
            }
        }
        
        return nil
    }
    
    /// Find and dismiss the wrapper's info window with save warning
    static func dismissInfoWindow(wrapperPid: Int32, config: TestConfig) -> Bool {
        logger.notice("🔍 Looking for wrapper info window from PID \(wrapperPid)...")
        
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < config.infoWindowDetectionTimeout {
            // Look for "Nancy Drew" titled window
            let options: CGWindowListOption = [.optionOnScreenOnly]
            let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
            
            logger.notice("  [DEBUG] Checking \(windowList.count) windows for info window...")
            
            // Find Nancy Drew info window
            for window in windowList {
                let windowName = window[kCGWindowName as String] as? String ?? "(unnamed)"
                let ownerName = window[kCGWindowOwnerName as String] as? String ?? "(no owner)"
                let windowPID = window[kCGWindowOwnerPID as String] as? Int32
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                let width = bounds["Width"] ?? 0
                let height = bounds["Height"] ?? 0
                
                // Show all windows with reasonable size
                if width > 50 && height > 50 {
                    logger.notice("  [DEBUG]   Window: '\(windowName)' Owner: '\(ownerName)' PID: \(windowPID ?? -1) Size: \(Int(width))x\(Int(height))")
                }
                
                // Check if window is owned by the wrapper app
                guard windowPID == wrapperPid else {
                    if width > 50 && height > 50 {
                        logger.notice("  [DEBUG]     ✗ PID \(windowPID ?? -1) doesn't match wrapper PID \(wrapperPid)")
                    }
                    continue
                }
                
                logger.notice("  [DEBUG]     ✓ PID matches wrapper")
                
                guard windowName == "Nancy Drew" else {
                    if width > 50 && height > 50 {
                        logger.notice("  [DEBUG]     ✗ Window name is '\(windowName)', not 'Nancy Drew'")
                    }
                    continue
                }
                
                logger.notice("  [DEBUG]     ✓ Window name matches 'Nancy Drew'")
                
                let rect = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: width,
                    height: height
                )
                
                // Info window is typically around 450x200-300
                let widthMatch = rect.width > 400 && rect.width < 500
                let heightMatch = rect.height > 50 && rect.height < 400
                logger.notice("  [DEBUG]     Width check: \(Int(rect.width)) (need 400-500): \(widthMatch ? "✓" : "✗")")
                logger.notice("  [DEBUG]     Height check: \(Int(rect.height)) (need 50-400): \(heightMatch ? "✓" : "✗")")
                
                if widthMatch && heightMatch {
                    logger.notice("  → Found info window: \(Int(rect.width))x\(Int(rect.height))")
                    
                    // Wait a moment for window to be fully initialized
                    Thread.sleep(forTimeInterval: 0.5)
                    
                    // Try to use Accessibility API to find and click the button
                    // Retry up to 5 times since window might not be immediately accessible
                    let app = AXUIElementCreateApplication(wrapperPid)
                    var windowsRef: CFTypeRef?
                    var windowsResult: AXError = .failure
                    var retryCount = 0
                    let maxRetries = 5
                    
                    while retryCount < maxRetries {
                        windowsResult = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
                        
                        if windowsResult == .success {
                            break
                        } else if windowsResult == .cannotComplete {
                            retryCount += 1
                            if retryCount < maxRetries {
                                logger.notice("  → Window not accessible yet, retrying (\(retryCount)/\(maxRetries))...")
                                Thread.sleep(forTimeInterval: 0.5)
                            }
                        } else {
                            // Other errors shouldn't be retried
                            break
                        }
                    }
                    
                    if windowsResult == .success, let windows = windowsRef as? [AXUIElement] {
                        logger.notice("  [DEBUG] Found \(windows.count) accessible windows")
                        
                        for (index, window) in windows.enumerated() {
                            var titleRef: CFTypeRef?
                            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                            let title = titleRef as? String ?? "(no title)"
                            logger.notice("  [DEBUG]   Accessible window [\(index)]: '\(title)'")
                            
                            if title.contains("Nancy Drew") {
                                logger.notice("  [DEBUG]     ✓ Found Nancy Drew window via Accessibility API")
                                
                                // Find button with title containing "Understand" or "OK" or "Continue"
                                if let button = findButton(in: window, containing: ["save-regularly-warning-confirm", "Understand", "OK", "Continue"]) {
                                    var positionRef: CFTypeRef?
                                    AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &positionRef)
                                    
                                    var sizeRef: CFTypeRef?
                                    AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &sizeRef)
                                    
                                    if let positionValue = positionRef, let sizeValue = sizeRef {
                                        var position = CGPoint.zero
                                        var size = CGSize.zero
                                        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                                        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                                        
                                        let clickPoint = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
                                        logger.notice("  ✓ Window has button - clicking at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
                                        InputControl.click(at: clickPoint)
                                        Thread.sleep(forTimeInterval: 0.5)
                                        
                                        logger.notice("✅ Info window dismissed")
                                        return true
                                    }
                                } else {
                                    // Button not found via AX tree (SwiftUI hosted views may not expose buttons).
                                    // Fall back to pressing Return key, which activates the default button.
                                    logger.notice("  ✗ Button not found via AX - pressing Return key as fallback")
                                    // InputControl.pressReturn()
                                    Thread.sleep(forTimeInterval: 0.5)
                                    logger.notice("✅ Info window dismissed via Return key")
                                    return true
                                }
                            }
                        }
                    }
                    
                    // Could not access window via Accessibility API - decode and report error
                    logger.critical("❌ Could not access info window via Accessibility API")
                    logger.critical("   Found window: \(Int(rect.width))x\(Int(rect.height)) at PID \(wrapperPid)")
                    logger.critical("   AXError code: \(windowsResult.rawValue)")
                    
                    // Decode the error and show troubleshooting if needed
                    switch windowsResult {
                    case .apiDisabled:
                        logger.critical("   Error: API Disabled (accessibility not enabled)")
                        logger.notice("   Troubleshooting:")
                        logger.notice("   1. Open System Settings → Privacy & Security → Accessibility")
                        logger.notice("   2. Ensure GamePuppeteer has Accessibility permission")
                        logger.notice("   3. Try relaunching GamePuppeteer after granting permission")
                    case .cannotComplete:
                        logger.critical("   Error: Cannot Complete (window not ready after \(maxRetries) retries)")
                    case .success:
                        logger.critical("   Error: Success (but windows array was invalid)")
                    case .failure:
                        logger.critical("   Error: Failure")
                    case .illegalArgument:
                        logger.critical("   Error: Illegal Argument")
                    case .invalidUIElement:
                        logger.critical("   Error: Invalid UI Element")
                    case .invalidUIElementObserver:
                        logger.critical("   Error: Invalid UI Element Observer")
                    case .attributeUnsupported:
                        logger.critical("   Error: Attribute Unsupported")
                    case .actionUnsupported:
                        logger.critical("   Error: Action Unsupported")
                    case .notificationUnsupported:
                        logger.critical("   Error: Notification Unsupported")
                    case .notImplemented:
                        logger.critical("   Error: Not Implemented")
                    case .notificationAlreadyRegistered:
                        logger.critical("   Error: Notification Already Registered")
                    case .notificationNotRegistered:
                        logger.critical("   Error: Notification Not Registered")
                    case .noValue:
                        logger.critical("   Error: No Value")
                    case .parameterizedAttributeUnsupported:
                        logger.critical("   Error: Parameterized Attribute Unsupported")
                    case .notEnoughPrecision:
                        logger.critical("   Error: Not Enough Precision")
                    @unknown default:
                        logger.critical("   Error: Unknown error")
                    }
                    return false
                }
            }
            
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        logger.notice("  → Info window not found (may have been auto-dismissed)")
        return false
    }
}

// MARK: - Game Focus Detection

enum GameFocusDetector {
    /// Check if game is currently focused (without trying to activate it)
    static func isGameFocused(pid: Int32, gameEngine: String) -> Bool {
        // For ScummVM games, check if fullscreen window is visible
        if gameEngine.lowercased().contains("scummvm") {
            return isFullscreenWindowVisible(pid: pid)
        }
        
        // For Wine and other games, check if process is active
        // Find the game process
        guard let gameApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            return false
        }
        
        // Check if game is active
        // For Wine apps, isActive may not work reliably, so also check if frontmost PID matches
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFrontmost = frontmostApp?.processIdentifier == pid
        return gameApp.isActive || isFrontmost
    }
    
    /// Check if a fullscreen window from the given PID is currently visible
    private static func isFullscreenWindowVisible(pid: Int32) -> Bool {
        // Create accessibility element for the application
        let app = AXUIElementCreateApplication(pid)
        
        // Get all windows
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return false
        }
        
        // Check each window for fullscreen attribute
        for window in windows {
            var fullscreenRef: CFTypeRef?
            let fullscreenResult = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef)
            
            if fullscreenResult == .success, let isFullscreen = fullscreenRef as? Bool, isFullscreen {
                return true
            }
        }
        
        return false
    }
    
    /// Wait for game to become focused, trying to activate it
    static func waitForGameToBecomeFocused(pid: Int32, gameEngine: String, timeout: TimeInterval = 10.0) -> Bool {
        logger.notice("\n[Step 3] Waiting for game to become active...")
        let startTime = Date()
        var lastPrintTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Find the game process using NSRunningApplication (like GameWrapper does)
            let gameApp = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
            
            if let gameApp = gameApp {
                // Try to activate the game (except for ScummVM which runs fullscreen)
                if !gameEngine.lowercased().contains("scummvm") {
                    _ = gameApp.activate(options: [.activateAllWindows])
                }
                
                // Wait a moment for activation to take effect
                Thread.sleep(forTimeInterval: 0.2)
                
                // Check if game is now active
                if isGameFocused(pid: pid, gameEngine: gameEngine) {
                    // Wait a bit longer to ensure window is fully rendered and stable
                    Thread.sleep(forTimeInterval: 10.0)
                    let elapsed = Date().timeIntervalSince(startTime)
                    logger.notice("✅ Game is active after \(String(format: "%.1f", elapsed))s")
                    
                    return true
                } else {
                    // Print status every 2 seconds
                    if Date().timeIntervalSince(lastPrintTime) >= 2.0 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        logger.notice("   [\(String(format: "%.1f", elapsed))s] Game app not active yet, retrying...")
                        
                        // Also show what is currently frontmost
                        let frontmostApp = NSWorkspace.shared.frontmostApplication
                        let frontmostName = frontmostApp?.localizedName ?? frontmostApp?.bundleIdentifier ?? "unknown"
                        let frontmostPid = frontmostApp?.processIdentifier ?? -1
                        logger.notice("   Current frontmost: \(frontmostName) (PID: \(frontmostPid)), Looking for PID: \(pid)")
                        lastPrintTime = Date()
                    }
                }
            } else {
                let elapsed = Int(Date().timeIntervalSince(startTime))
                logger.notice("   [\(elapsed)s] Game app not found in running applications...")
                
                if elapsed >= Int(timeout) {
                    logger.critical("❌ Timeout: Could not find game in running applications")
                    return false
                }
            }
            
            // Wait before next attempt
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        logger.critical("❌ Timeout: Game did not become active within \(Int(timeout))s")
        return false
    }
}

// MARK: - Window Detection

/// Named GameProcessInfo to avoid shadowing Foundation.ProcessInfo — this
/// target also compiles Shared/ sources that use the Foundation type.
struct GameProcessInfo {
    let pid: Int32
    let name: String
}

enum WindowDetector {
    /// Get all processes for a specific game engine
    static func getAllProcesses(for gameEngine: String) -> [GameProcessInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid,comm"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        var processes: [GameProcessInfo] = []
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n")
                for line in lines.dropFirst() {  // Skip header
                    let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard parts.count == 2,
                          let pid = Int32(parts[0]) else { continue }
                    
                    let command = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    let basename = (command as NSString).lastPathComponent
                    
                    // Filter based on game engine
                    let shouldInclude: Bool
                    if gameEngine.lowercased().contains("wine") {
                        // Wine: look for wine processes and .exe files
                        shouldInclude = command.contains("wine") || command.hasSuffix(".exe")
                    } else if gameEngine.lowercased().contains("scummvm") {
                        // ScummVM: look for scummvm process
                        shouldInclude = command.contains("scummvm")
                    } else {
                        // Other engines: include all (will filter by name later)
                        shouldInclude = true
                    }
                    
                    if shouldInclude {
                        processes.append(GameProcessInfo(pid: pid, name: basename))
                    }
                }
            }
        } catch {
            logger.error("  ⚠️  Error checking processes: \(error)")
        }
        
        return processes
    }
    /// Wait for window with app name to appear (handles Wine and ScummVM)
    /// Returns the game process PID if found, nil otherwise
    static func waitForWindow(appName: String, wrapperPid: Int32, gameEngine: String, gameExeName: String, prefixPath: URL, timeout: TimeInterval) -> Int32? {
        logger.notice("⏳ Waiting for game window to appear (timeout: \(Int(timeout))s)...")
        logger.notice("   Engine: \(gameEngine)")
        
        // Determine what process to look for based on engine
        let processToFind: String
        if gameEngine.lowercased().contains("wine") {
            processToFind = gameExeName  // Wine: look for game executable (e.g., Game.exe)
            logger.notice("   Looking for Wine process: \(processToFind)")
            logger.notice("   Wine prefix: \(prefixPath.path)")
        } else if gameEngine.lowercased().contains("scummvm") {
            processToFind = "scummvm"  // ScummVM: look for scummvm process
            logger.notice("   Looking for ScummVM process: \(processToFind)")
        } else {
            processToFind = gameExeName  // Default: look for game executable
            logger.notice("   Looking for process: \(processToFind)")
        }
        
        let startTime = Date()
        var lastPrintTime = Date()
        var gamePid: Int32?
        
        // Step 1: Wait for game executable/engine process to appear
        logger.notice("[Step 1] Monitoring for \(processToFind) process...")
        let processTimeout: TimeInterval = timeout * 0.7  // Use 70% of timeout for process detection
        
        while Date().timeIntervalSince(startTime) < processTimeout {
            let processes = getAllProcesses(for: gameEngine)
            
            // Print debug info every 5 seconds
            if Date().timeIntervalSince(lastPrintTime) >= 5 {
                let elapsed = Int(Date().timeIntervalSince(startTime))
                logger.notice("   [\(elapsed)s] Checking for \(processToFind) process...")
                logger.notice("   Found \(processes.count) total processes")
                lastPrintTime = Date()
            }
            
            // Look for the specific process
            if let gameProcess = processes.first(where: { $0.name.lowercased() == processToFind.lowercased() }) {
                logger.notice("✅ \(processToFind) process detected (PID: \(gameProcess.pid))")
                gamePid = gameProcess.pid
                break
            }
            
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        guard let pid = gamePid else {
            logger.critical("❌ Timeout: \(processToFind) process not detected")
            return nil
        }
        
        // Step 2: Wait for window owned by game process
        logger.notice("\n[Step 2] Monitoring for windows from \(processToFind) (PID: \(pid))...")
        let windowStartTime = Date()
        let windowTimeout: TimeInterval = 30.0
        
        while Date().timeIntervalSince(windowStartTime) < windowTimeout {
            let elapsed = Int(Date().timeIntervalSince(windowStartTime))
            
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            
            let gameWindows = windowList.filter { window in
                if let windowPID = window[kCGWindowOwnerPID as String] as? Int32 {
                    return windowPID == pid
                }
                return false
            }
            
            if !gameWindows.isEmpty {
                
                let totalElapsed = Date().timeIntervalSince(startTime)
                logger.notice("✅ Game window detected after \(String(format: "%.1f", totalElapsed))s")
                logger.notice("   Found \(gameWindows.count) window(s) from \(processToFind)")
                
                for (index, window) in gameWindows.enumerated() {
                    let windowName = window[kCGWindowName as String] as? String ?? "(unnamed)"
                    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                    let width = Int(bounds["Width"] ?? 0)
                    let height = Int(bounds["Height"] ?? 0)
                    logger.notice("   [\(index + 1)] \(windowName) - \(width)x\(height)")
                }
                
                // Wait for window to be focused
                if !GameFocusDetector.waitForGameToBecomeFocused(pid: pid, gameEngine: gameEngine) {
                    return nil
                }
                
                NSSound.beep()
                
                // Take screenshots for verification
                let timestamp = Int(Date().timeIntervalSince1970)
                
                // First, take a screenshot of just the game window
                let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                if let gameWindow = windowList.first(where: { window in
                    guard let windowPID = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
                    return windowPID == pid
                }), let windowNumber = gameWindow[kCGWindowNumber as String] as? Int32 {
                    
                    // Capture just this specific window using its window ID
                    let windowScreenshotPath = "/tmp/game-window-detected-\(timestamp).png"
                    let windowScreenshotTask = Process()
                    windowScreenshotTask.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    windowScreenshotTask.arguments = ["-x", "-l\(windowNumber)", windowScreenshotPath]
                    try? windowScreenshotTask.run()
                    windowScreenshotTask.waitUntilExit()
                    logger.notice("📸 Window screenshot: \(windowScreenshotPath)")
                } else {
                    logger.error("⚠️  Could not get window ID for screenshot")
                }
                
                // Then, take a screenshot of the whole screen
                let fullScreenshotPath = "/tmp/game-fullscreen-detected-\(timestamp).png"
                let fullScreenshotTask = Process()
                fullScreenshotTask.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                fullScreenshotTask.arguments = ["-x", fullScreenshotPath]
                try? fullScreenshotTask.run()
                fullScreenshotTask.waitUntilExit()
                logger.notice("📸 Full screen screenshot: \(fullScreenshotPath)")
                
                return pid
            }
            
            if elapsed % 5 == 0 {
                logger.notice("   [\(elapsed)s] No windows yet, still waiting...")
            }
            
            Thread.sleep(forTimeInterval: 0.2)
        }
        
        logger.critical("❌ Timeout: \(processToFind) process found but no windows appeared")
        logger.critical("   Final window list:")
        printAllWindows()
        return nil
    }
    
    /// Print all current windows for debugging
    static func printAllWindows() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        
        logger.notice("📋 Current windows on screen:")
        for (index, window) in windowList.enumerated() {
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? "(no owner)"
            let windowTitle = window[kCGWindowName as String] as? String ?? "(no title)"
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = Int(bounds["Width"] ?? 0)
            let height = Int(bounds["Height"] ?? 0)
            
            // Only show windows with reasonable size (filter out tiny helper windows)
            if width > 50 && height > 50 {
                logger.notice("   [\(index)] Owner: '\(ownerName)' | Title: '\(windowTitle)' | Size: \(width)x\(height)")
            }
        }
    }
    
    /// Find window for game (handles native apps, Wine, and ScummVM)
    static func findGameWindow(appName: String) -> [String: Any]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Extract game-specific part after "Nancy Drew"
        let gameTitle = appName.replacingOccurrences(of: "Nancy Drew - ", with: "")
                              .replacingOccurrences(of: "Nancy Drew: ", with: "")
        
        // Look for windows owned by the app name or game engines
        return windowList.first { window in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else { return false }
            let windowTitle = window[kCGWindowName as String] as? String ?? ""
            
            // Check if owned by our app or GameWrapper
            // Match "Nancy Drew.*<game title>" pattern (handles - vs : and truncation)
            if ownerName.contains("Nancy Drew") && ownerName.contains(gameTitle.prefix(20)) {
                return true
            }
            if ownerName.contains("GameWrapper") {
                return true
            }
            
            // For Wine apps, check the window title for Nancy Drew games
            if ownerName.contains("wine") || ownerName.contains("wine64") || ownerName.hasSuffix(".exe") {
                // Check if window title contains Nancy Drew and the game name
                if windowTitle.contains("Nancy Drew") && windowTitle.contains(gameTitle.prefix(20)) {
                    // Exclude Wine's own windows
                    let excludedTitles = ["winedbg", "winecfg", "Wine", "winemenubuilder"]
                    if !excludedTitles.contains(where: { windowTitle.contains($0) }) {
                        return true
                    }
                }
            }
            
            // For ScummVM, check if window is owned by scummvm
            if ownerName.lowercased().contains("scummvm") {
                return true
            }
            
            return false
        }
    }
    
    /// Get window bounds (handles multiple game engines)
    static func getWindowBounds(for appName: String) -> CGRect? {
        guard let window = findGameWindow(appName: appName),
              let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        
        return CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
    }
}
