import Foundation
import AppKit
import CoreGraphics

// MARK: - Test Logic

func attemptQuit(appName: String, app: NSRunningApplication, gamePid: Int32?, gameEngine: String) -> Bool {
    print("🎮 Attempting to quit game...")
    
    // Search for both "interactive" and "Exit Game" simultaneously
    print("🔍 Searching for 'Exit Game', 'Quit', 'interactive' text and quit button image...")
    
    var clickedInteractive = false
    var clickedExitButton = false
    let quitTimeout: TimeInterval = 60
    let startTime = Date()
    var attempt = 0
    
    // Get path to quit button image
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let scriptDir = scriptURL.deletingLastPathComponent()
    let quitButtonImagePath = scriptDir.appendingPathComponent("assets/quit-button.png").path
    
    while Date().timeIntervalSince(startTime) < quitTimeout {
        attempt += 1
        let iterationStartTime = Date()
        
        if attempt == 1 {
            NSSound.beep()
        }
        
        // Check if game is still focused
        guard let pid = gamePid else {
            print("⚠️  No game PID available, cannot check focus")
            break
        }
        
        if !GameFocusDetector.isGameFocused(pid: pid, gameEngine: gameEngine) {
            if clickedExitButton {
                print("⚠️  Game lost focus after clicking exit button - stopping OCR")
                // Exit button was clicked, let waitForTermination handle waiting for quit
                return true
            } else {
                print("❌ Game lost focus before clicking exit button - test failed")
                print("⚠️  Force quitting game...")
                ProcessManager.forceQuit(app, gameEngine: gameEngine)
                return false
            }
        }
        print("")
        print("\u{001B}[1m  → Attempt \(attempt)\u{001B}[0m (elapsed: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)")
        
        // Take screenshot
        guard let screenshotPath = ScreenshotOCR.captureScreen() else {
            print("⚠️  Failed to capture screenshot")
            continue
        }
        
        let searchStartTime = Date()
        
        // Run OCR and template matching in parallel for faster results
        let dispatchGroup = DispatchGroup()
        var foundTexts: [String: CGRect] = [:]
        var quitButtonLocation: CGRect?
        
        // Search for text in parallel
        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            foundTexts = ScreenshotOCR.findText(["Exit Game", "Quit", "interactive"], in: screenshotPath, app: app)
            dispatchGroup.leave()
        }
        
        // Search for quit button image in parallel
        if FileManager.default.fileExists(atPath: quitButtonImagePath) {
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                quitButtonLocation = ScreenshotOCR.findImage(quitButtonImagePath, in: screenshotPath)
                dispatchGroup.leave()
            }
        } else if attempt == 1 {
            print("  ℹ️  Quit button image not found at: \(quitButtonImagePath)")
        }
        
        // Wait for both operations to complete
        dispatchGroup.wait()
        
        let searchDuration = Date().timeIntervalSince(searchStartTime)
        print("    ⏱️  Search took \(String(format: "%.2f", searchDuration))s")
        
        // Clean up screenshot
        try? FileManager.default.removeItem(atPath: screenshotPath)
        
        // If we found "Exit Game", "Quit", or the button image, click it
        let exitLocation = foundTexts["Exit Game"] ?? foundTexts["Quit"] ?? quitButtonLocation
        
        if let exitLocation = exitLocation {
            // Check if game is still in focus before clicking
            guard let pid = gamePid else {
                print("⚠️  No game PID available, cannot check focus before clicking")
                break
            }
            
            if !GameFocusDetector.isGameFocused(pid: pid, gameEngine: gameEngine) {
                if clickedExitButton {
                    print("⚠️  Game lost focus after clicking exit button - stopping OCR")
                    return true
                } else {
                    print("❌ Game lost focus before clicking exit button - test failed")
                    print("⚠️  Force quitting game...")
                    ProcessManager.forceQuit(app, gameEngine: gameEngine)
                    return false
                }
            }
            
            // Game is in focus, safe to click
            if !clickedExitButton {
                print("  ✓ Found 'Exit Game' button, clicking...")
                clickedExitButton = true
                
                if attempt == 1 {
                    NSSound.beep()
                }
            } else {
                print("  ✓ Clicking 'Exit Game' button again...")
            }
            
            // Get screen backing scale factor (2.0 for retina, 1.0 for non-retina)
            let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
            
            // Convert pixel coordinates to screen points for retina displays
            // screencapture returns pixel coordinates, but clicking requires points
            var clickPoint = CGPoint(
                x: exitLocation.midX / backingScaleFactor,
                y: exitLocation.midY / backingScaleFactor
            )
            
            if backingScaleFactor > 1.0 {
                print("  ℹ️  Retina display detected (scale: \(backingScaleFactor)x) - converting coordinates")
                print("     Pixel coords: (\(Int(exitLocation.midX)), \(Int(exitLocation.midY))) → Point coords: (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
            }
            
            // Special case for Secret of the Scarlet Hand - hitbox is shifted up by half its height
            if appName.contains("Scarlet Hand") {
                let shiftAmount = exitLocation.height / (2.0 * backingScaleFactor)
                clickPoint.y -= shiftAmount
                print("  ℹ️  Adjusting click position for Scarlet Hand (shift up by \(Int(shiftAmount))px)")
            }
            
            InputControl.click(at: clickPoint)
            Thread.sleep(forTimeInterval: 1)
            
            // Move mouse to bottom-right corner to avoid obscuring UI elements in next screenshot
            let screenBounds = NSScreen.main?.frame ?? CGRect.zero
            let cornerPoint = CGPoint(x: screenBounds.maxX - 10, y: screenBounds.maxY - 10)
            CGWarpMouseCursorPosition(cornerPoint)
            
            
            // Check if app has quit
            if !ProcessManager.isRunning(app, gamePid: gamePid) {
                print("✅ Game exited successfully")
                return true
            }
        }
        
        // If we found "interactive" but not "Exit Game", and we haven't clicked it yet
        if let interactiveLocation = foundTexts["interactive"], !clickedInteractive {
            print("  ✓ Found 'interactive' button (but no 'Exit Game'), clicking to enable menu...")
            Thread.sleep(forTimeInterval: 1)
            InputControl.click(at: CGPoint(x: interactiveLocation.midX, y: interactiveLocation.midY))
            clickedInteractive = true
            Thread.sleep(forTimeInterval: 2)
            // Continue searching for Exit Game
        }
        
        // Wait to maintain minimum 0.2s interval between iterations
        let iterationDuration = Date().timeIntervalSince(iterationStartTime)
        print("    ⏱️  Total iteration took \(String(format: "%.2f", iterationDuration))s")
        
        if attempt == 1 {
            NSSound.beep()
        }
        
        let minimumInterval = 0.2
        let remainingTime = max(0, minimumInterval - iterationDuration)
        if remainingTime > 0 {
            Thread.sleep(forTimeInterval: remainingTime)
        }
    }
    
    print("❌ OCR failed to find Exit button within \(Int(quitTimeout))s timeout")
    print("⚠️  Force quitting game...")
    ProcessManager.forceQuit(app, gameEngine: gameEngine)
    return false
}

func runTest(config: TestConfig, gameExeName: String, winePrefix: URL) -> Int32 {
    print("🎮 Starting automated game test")
    print("   App: \(config.appPath)")
    print("   Engine: \(config.gameEngine)")
    print("   Executable: \(gameExeName)")
    print("   Max runtime: \(Int(config.maxRuntime))s")
    if config.debugMode {
        print("   Debug mode: enabled")
    }
    if let logPath = config.logFilePath {
        print("   Log file: \(logPath)")
    }
    print("")
    
    // Check Screen Recording permission early
    if !WindowDetector.checkScreenRecordingPermission() {
        print("❌ Test cannot proceed without Screen Recording permission")
        return 1
    }
    
    // Launch game with debug and log flags if enabled
    var arguments: [String] = []
    if config.debugMode {
        arguments.append("--debug")
    }
    if let logPath = config.logFilePath {
        arguments.append("--log")
        arguments.append(logPath)
    }
    guard let app = ProcessManager.launch(appPath: config.appPath, arguments: arguments) else {
        print("❌ Failed to launch game")
        return 1
    }
    
    let appName = app.localizedName ?? "GameWrapper"
    print("ℹ️  Game process: \(appName) (PID: \(app.processIdentifier))")
    
    // For Wine games, wait for and dismiss the info window
    if config.gameEngine.lowercased().contains("wine") {
        print("\n⚠️  Wine game detected - checking for info window...")
        Thread.sleep(forTimeInterval: 1)  // Give app time to show window
        
        if !InfoWindowHandler.dismissInfoWindow(wrapperPid: Int32(app.processIdentifier), config: config) {
            print("❌ Failed to dismiss info window")
            ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
            return 1
        }
        print("")
    }
    
    // Wait for window and get game PID
    guard let gamePid = WindowDetector.waitForWindow(appName: appName, wrapperPid: Int32(app.processIdentifier), gameEngine: config.gameEngine, gameExeName: gameExeName, prefixPath: winePrefix, timeout: config.windowDetectTimeout) else {
        ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
        return 1
    }
    
    print("ℹ️  Game process PID: \(gamePid)")
    
    // Write PIDs to file so wrapper script can clean up on signals
    SignalHandler.setup(app: app, gamePid: gamePid)
    
    // Attempt to quit
    let ocrSuccess = attemptQuit(appName: appName, app: app, gamePid: gamePid, gameEngine: config.gameEngine)
    
    // If OCR failed, we already force quit - return failure
    if !ocrSuccess {
        print("❌ Test failed: OCR could not find Exit button")
        return 1
    }
    
    // Wait for clean exit
    print("⏳ Waiting for game to exit...")
    if ProcessManager.waitForTermination(app, gamePid: gamePid, timeout: config.quitTimeout) {
        print("✅ Game exited cleanly")
        return 0
    } else {
        print("⚠️  Game did not exit cleanly, force quitting...")
        ProcessManager.forceQuit(app, gameEngine: config.gameEngine)
        Thread.sleep(forTimeInterval: 2)
        
        if app.isTerminated {
            print("✅ Game force-quit successful")
            return 2  // Return 2 to indicate forced quit
        } else {
            print("❌ Failed to quit game")
            return 1
        }
    }
}
