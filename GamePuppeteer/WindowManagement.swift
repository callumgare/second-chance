//
//  WindowManagement.swift
//  GameTester
//
//  Window detection, focus management, and accessibility handling

import Foundation
import AppKit
import CoreGraphics

// MARK: - Info Window Handler

enum InfoWindowHandler {
    /// Recursively search for a button with a title containing any of the search terms
    static func findButton(in element: AXUIElement, containing searchTerms: [String]) -> AXUIElement? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String
        
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""
        
        // Check if this is a button with matching title
        if role == kAXButtonRole as String {
            for term in searchTerms {
                if title.lowercased().contains(term.lowercased()) {
                    print("  [DEBUG]     ✓ Found button: '\(title)'")
                    return element
                }
            }
        }
        
        // Recursively search children
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        
        if childrenResult == .success, let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let button = findButton(in: child, containing: searchTerms) {
                    return button
                }
            }
        }
        
        return nil
    }
    
    /// Find and dismiss the wrapper's info window with save warning
    static func dismissInfoWindow(wrapperPid: Int32, config: TestConfig) -> Bool {
        print("🔍 Looking for wrapper info window from PID \(wrapperPid)...")
        
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < config.infoWindowDetectionTimeout {
            // Look for "Nancy Drew" titled window
            let options: CGWindowListOption = [.optionOnScreenOnly]
            let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
            
            print("  [DEBUG] Checking \(windowList.count) windows for info window...")
            
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
                    print("  [DEBUG]   Window: '\(windowName)' Owner: '\(ownerName)' PID: \(windowPID ?? -1) Size: \(Int(width))x\(Int(height))")
                }
                
                // Check if window is owned by the wrapper app
                guard windowPID == wrapperPid else {
                    if width > 50 && height > 50 {
                        print("  [DEBUG]     ✗ PID \(windowPID ?? -1) doesn't match wrapper PID \(wrapperPid)")
                    }
                    continue
                }
                
                print("  [DEBUG]     ✓ PID matches wrapper")
                
                guard windowName == "Nancy Drew" else {
                    if width > 50 && height > 50 {
                        print("  [DEBUG]     ✗ Window name is '\(windowName)', not 'Nancy Drew'")
                    }
                    continue
                }
                
                print("  [DEBUG]     ✓ Window name matches 'Nancy Drew'")
                
                let rect = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: width,
                    height: height
                )
                
                // Info window is typically around 450x200-300
                let widthMatch = rect.width > 400 && rect.width < 500
                let heightMatch = rect.height > 50 && rect.height < 400
                print("  [DEBUG]     Width check: \(Int(rect.width)) (need 400-500): \(widthMatch ? "✓" : "✗")")
                print("  [DEBUG]     Height check: \(Int(rect.height)) (need 50-400): \(heightMatch ? "✓" : "✗")")
                
                if widthMatch && heightMatch {
                    print("  → Found info window: \(Int(rect.width))x\(Int(rect.height))")
                    
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
                                print("  → Window not accessible yet, retrying (\(retryCount)/\(maxRetries))...")
                                Thread.sleep(forTimeInterval: 0.5)
                            }
                        } else {
                            // Other errors shouldn't be retried
                            break
                        }
                    }
                    
                    if windowsResult == .success, let windows = windowsRef as? [AXUIElement] {
                        print("  [DEBUG] Found \(windows.count) accessible windows")
                        
                        for (index, window) in windows.enumerated() {
                            var titleRef: CFTypeRef?
                            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                            let title = titleRef as? String ?? "(no title)"
                            print("  [DEBUG]   Accessible window [\(index)]: '\(title)'")
                            
                            if title.contains("Nancy Drew") {
                                print("  [DEBUG]     ✓ Found Nancy Drew window via Accessibility API")
                                
                                // Find button with title containing "Understand" or "OK" or "Continue"
                                if let button = findButton(in: window, containing: ["Understand", "OK", "Continue"]) {
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
                                        print("  ✓ Window has button - clicking at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
                                        InputControl.click(at: clickPoint)
                                        Thread.sleep(forTimeInterval: 0.5)
                                        
                                        print("✅ Info window dismissed")
                                        return true
                                    }
                                } else {
                                    print("  ✗ Window does not have a button - continuing without clicking")
                                    return true
                                }
                            }
                        }
                    }
                    
                    // Could not access window via Accessibility API - decode and report error
                    print("❌ Could not access info window via Accessibility API")
                    print("   Found window: \(Int(rect.width))x\(Int(rect.height)) at PID \(wrapperPid)")
                    print("   AXError code: \(windowsResult.rawValue)")
                    
                    // Decode the error and show troubleshooting if needed
                    switch windowsResult {
                    case .apiDisabled:
                        print("   Error: API Disabled (accessibility not enabled)")
                        print("")
                        print("   Troubleshooting:")
                        print("   1. Open System Settings → Privacy & Security → Accessibility")
                        print("   2. Ensure Terminal (or your IDE) has Accessibility permissions")
                        print("   3. Try restarting the application after granting permissions")
                    case .cannotComplete:
                        print("   Error: Cannot Complete (window not ready after \(maxRetries) retries)")
                    case .success:
                        print("   Error: Success (but windows array was invalid)")
                    case .failure:
                        print("   Error: Failure")
                    case .illegalArgument:
                        print("   Error: Illegal Argument")
                    case .invalidUIElement:
                        print("   Error: Invalid UI Element")
                    case .invalidUIElementObserver:
                        print("   Error: Invalid UI Element Observer")
                    case .attributeUnsupported:
                        print("   Error: Attribute Unsupported")
                    case .actionUnsupported:
                        print("   Error: Action Unsupported")
                    case .notificationUnsupported:
                        print("   Error: Notification Unsupported")
                    case .notImplemented:
                        print("   Error: Not Implemented")
                    case .notificationAlreadyRegistered:
                        print("   Error: Notification Already Registered")
                    case .notificationNotRegistered:
                        print("   Error: Notification Not Registered")
                    case .noValue:
                        print("   Error: No Value")
                    case .parameterizedAttributeUnsupported:
                        print("   Error: Parameterized Attribute Unsupported")
                    case .notEnoughPrecision:
                        print("   Error: Not Enough Precision")
                    @unknown default:
                        print("   Error: Unknown error")
                    }
                    return false
                }
            }
            
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        print("  → Info window not found (may have been auto-dismissed)")
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
        print("\n[Step 3] Waiting for game to become active...")
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
                    print("✅ Game is active after \(String(format: "%.1f", elapsed))s")
                    
                    return true
                } else {
                    // Print status every 2 seconds
                    if Date().timeIntervalSince(lastPrintTime) >= 2.0 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        print("   [\(String(format: "%.1f", elapsed))s] Game app not active yet, retrying...")
                        
                        // Also show what is currently frontmost
                        let frontmostApp = NSWorkspace.shared.frontmostApplication
                        let frontmostName = frontmostApp?.localizedName ?? frontmostApp?.bundleIdentifier ?? "unknown"
                        let frontmostPid = frontmostApp?.processIdentifier ?? -1
                        print("   Current frontmost: \(frontmostName) (PID: \(frontmostPid)), Looking for PID: \(pid)")
                        lastPrintTime = Date()
                    }
                }
            } else {
                let elapsed = Int(Date().timeIntervalSince(startTime))
                print("   [\(elapsed)s] Game app not found in running applications...")
                
                if elapsed >= Int(timeout) {
                    print("❌ Timeout: Could not find game in running applications")
                    return false
                }
            }
            
            // Wait before next attempt
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        print("❌ Timeout: Game did not become active within \(Int(timeout))s")
        return false
    }
}

// MARK: - Window Detection

struct ProcessInfo {
    let pid: Int32
    let name: String
}

enum WindowDetector {
    /// Check if we have Screen Recording permission (needed to read window titles)
    static func checkScreenRecordingPermission() -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        
        // Check if we can read window titles - if all are unnamed/empty, we likely don't have permission
        var namedWindowCount = 0
        var totalWindowCount = 0
        
        for window in windowList {
            let windowName = window[kCGWindowName as String] as? String ?? ""
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            
            // Only count windows with reasonable owners (not system windows)
            if !ownerName.isEmpty && ownerName != "Window Server" && ownerName != "Dock" {
                totalWindowCount += 1
                if !windowName.isEmpty {
                    namedWindowCount += 1
                }
            }
        }
        
        // If we found windows but none have names, we likely don't have permission
        let hasPermission = totalWindowCount == 0 || namedWindowCount > 0
        
        if !hasPermission {
            print("")
            print("⚠️  Screen Recording permission required")
            print("")
            print("GameTester cannot read window titles. This is required to detect and interact with game windows.")
            print("")
            print("Opening System Settings to grant permission...")
            print("")
            
            // Open System Settings to the Screen Recording permission pane
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
            
            print("Please:")
            print("  1. Find and enable Terminal (or your IDE) in the list")
            print("  2. Click the lock icon and authenticate if needed")
            print("  3. Restart Terminal/IDE (required for permission to take effect)")
            print("")
            print("After granting permission and restarting, please run this test again.")
            print("")
        }
        
        return hasPermission
    }
    
    /// Get all processes for a specific game engine
    static func getAllProcesses(for gameEngine: String) -> [ProcessInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid,comm"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        var processes: [ProcessInfo] = []
        
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
                        processes.append(ProcessInfo(pid: pid, name: basename))
                    }
                }
            }
        } catch {
            print("  ⚠️  Error checking processes: \(error)")
        }
        
        return processes
    }
    /// Wait for window with app name to appear (handles Wine and ScummVM)
    /// Returns the game process PID if found, nil otherwise
    static func waitForWindow(appName: String, wrapperPid: Int32, gameEngine: String, gameExeName: String, prefixPath: URL, timeout: TimeInterval) -> Int32? {
        print("⏳ Waiting for game window to appear (timeout: \(Int(timeout))s)...)")
        print("   Engine: \(gameEngine)")
        
        // Determine what process to look for based on engine
        let processToFind: String
        if gameEngine.lowercased().contains("wine") {
            processToFind = gameExeName  // Wine: look for game executable (e.g., Game.exe)
            print("   Looking for Wine process: \(processToFind)")
            print("   Wine prefix: \(prefixPath.path)")
        } else if gameEngine.lowercased().contains("scummvm") {
            processToFind = "scummvm"  // ScummVM: look for scummvm process
            print("   Looking for ScummVM process: \(processToFind)")
        } else {
            processToFind = gameExeName  // Default: look for game executable
            print("   Looking for process: \(processToFind)")
        }
        print("")
        
        let startTime = Date()
        var lastPrintTime = Date()
        var gamePid: Int32?
        
        // Step 1: Wait for game executable/engine process to appear
        print("[Step 1] Monitoring for \(processToFind) process...")
        let processTimeout: TimeInterval = timeout * 0.7  // Use 70% of timeout for process detection
        
        while Date().timeIntervalSince(startTime) < processTimeout {
            let processes = getAllProcesses(for: gameEngine)
            
            // Print debug info every 5 seconds
            if Date().timeIntervalSince(lastPrintTime) >= 5 {
                let elapsed = Int(Date().timeIntervalSince(startTime))
                print("   [\(elapsed)s] Checking for \(processToFind) process...")
                print("   Found \(processes.count) total processes")
                lastPrintTime = Date()
            }
            
            // Look for the specific process
            if let gameProcess = processes.first(where: { $0.name.lowercased() == processToFind.lowercased() }) {
                print("✅ \(processToFind) process detected (PID: \(gameProcess.pid))")
                gamePid = gameProcess.pid
                break
            }
            
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        guard let pid = gamePid else {
            print("❌ Timeout: \(processToFind) process not detected")
            return nil
        }
        
        // Step 2: Wait for window owned by game process
        print("\n[Step 2] Monitoring for windows from \(processToFind) (PID: \(pid))...")
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
                print("✅ Game window detected after \(String(format: "%.1f", totalElapsed))s")
                print("   Found \(gameWindows.count) window(s) from \(processToFind)")
                
                for (index, window) in gameWindows.enumerated() {
                    let windowName = window[kCGWindowName as String] as? String ?? "(unnamed)"
                    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                    let width = Int(bounds["Width"] ?? 0)
                    let height = Int(bounds["Height"] ?? 0)
                    print("   [\(index + 1)] \(windowName) - \(width)x\(height)")
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
                    print("📸 Window screenshot: \(windowScreenshotPath)")
                } else {
                    print("⚠️  Could not get window ID for screenshot")
                }
                
                // Then, take a screenshot of the whole screen
                let fullScreenshotPath = "/tmp/game-fullscreen-detected-\(timestamp).png"
                let fullScreenshotTask = Process()
                fullScreenshotTask.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                fullScreenshotTask.arguments = ["-x", fullScreenshotPath]
                try? fullScreenshotTask.run()
                fullScreenshotTask.waitUntilExit()
                print("📸 Full screen screenshot: \(fullScreenshotPath)")
                
                return pid
            }
            
            if elapsed % 5 == 0 {
                print("   [\(elapsed)s] No windows yet, still waiting...")
            }
            
            Thread.sleep(forTimeInterval: 0.2)
        }
        
        print("❌ Timeout: \(processToFind) process found but no windows appeared")
        print("   Final window list:")
        printAllWindows()
        return nil
    }
    
    /// Print all current windows for debugging
    static func printAllWindows() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        
        print("📋 Current windows on screen:")
        for (index, window) in windowList.enumerated() {
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? "(no owner)"
            let windowTitle = window[kCGWindowName as String] as? String ?? "(no title)"
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = Int(bounds["Width"] ?? 0)
            let height = Int(bounds["Height"] ?? 0)
            
            // Only show windows with reasonable size (filter out tiny helper windows)
            if width > 50 && height > 50 {
                print("   [\(index)] Owner: '\(ownerName)' | Title: '\(windowTitle)' | Size: \(width)x\(height)")
            }
        }
        print("")
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
