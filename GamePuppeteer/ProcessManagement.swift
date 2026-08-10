//
//  ProcessManagement.swift
//  GameTester
//
//  Process lifecycle and signal handling

import Foundation
import AppKit

// MARK: - Signal Handling

// Global variables for signal handler
var globalWrapperPid: Int32 = 0
var globalGamePid: Int32 = 0

// Top-level function that can be used as signal handler
func handleTermination(_ sig: Int32) {
    write(STDERR_FILENO, "\n⚠️  Received termination signal - cleaning up game processes...\n", 67)
    
    if globalWrapperPid > 0 {
        write(STDERR_FILENO, "  → Killing wrapper process...\n", 33)
        kill(globalWrapperPid, SIGKILL)
    }
    
    if globalGamePid > 0 {
        write(STDERR_FILENO, "  → Killing game process...\n", 30)
        kill(globalGamePid, SIGKILL)
    }
    
    // Kill any remaining wine processes  
    write(STDERR_FILENO, "  → Killing wine processes...\n", 32)
    
    // Use posix_spawn since we can't use Process in signal handler
    var pid: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("pkill"),
        strdup("-9"),
        strdup("-f"),
        strdup("wine"),
        nil
    ]
    
    posix_spawn(&pid, "/usr/bin/pkill", nil, nil, &argv, nil)
    
    // Free the duplicated strings
    for arg in argv {
        free(arg)
    }
    
    write(STDERR_FILENO, "  ✓ Cleanup complete\n", 23)
    
    _exit(143)
}

enum SignalHandler {
    /// Setup signal handlers to clean up game on script termination
    static func setup(app: NSRunningApplication, gamePid: Int32?) {
        globalWrapperPid = app.processIdentifier
        globalGamePid = gamePid ?? 0
        
        print("  → Setting up signal handlers (wrapper PID: \(globalWrapperPid), game PID: \(globalGamePid))...")
        
        // Use the top-level function directly
        signal(SIGINT, handleTermination)
        signal(SIGTERM, handleTermination)
        signal(SIGHUP, handleTermination)
        
        print("  → Signal handlers registered")
    }
}

// MARK: - Process Management

enum ProcessManager {
    /// Launch application with optional arguments and return NSRunningApplication
    static func launch(appPath: String, arguments: [String] = []) -> NSRunningApplication? {
        print("🚀 Launching game...")
        if !arguments.isEmpty {
            print("   Arguments: \(arguments.joined(separator: " "))")
        }
        
        let url = URL(fileURLWithPath: appPath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        
        var app: NSRunningApplication?
        let semaphore = DispatchSemaphore(value: 0)
        
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApp, error in
            if let error = error {
                print("❌ Failed to launch: \(error.localizedDescription)")
            }
            app = runningApp
            semaphore.signal()
        }
        
        semaphore.wait()
        return app
    }
    
    /// Check if app or specific game process is still running
    static func isRunning(_ app: NSRunningApplication, gamePid: Int32?) -> Bool {
        var wrapperRunning = false
        var gameRunning = false
        
        // Check wrapper process using kill(pid, 0) - the only reliable method
        let wrapperKillResult = kill(app.processIdentifier, 0)
        wrapperRunning = (wrapperKillResult == 0)
        if wrapperKillResult != 0 {
            let err = errno
            print("   [DEBUG] Wrapper PID \(app.processIdentifier): kill(pid, 0)=\(wrapperKillResult), errno=\(err), wrapperRunning=\(wrapperRunning)")
        } else {
            print("   [DEBUG] Wrapper PID \(app.processIdentifier): kill(pid, 0)=\(wrapperKillResult), wrapperRunning=\(wrapperRunning)")
        }
        
        // Check game process using kill(pid, 0)
        if let pid = gamePid {
            let killResult = kill(pid, 0)
            gameRunning = (killResult == 0)
            if killResult != 0 {
                let err = errno
                print("   [DEBUG] Game PID \(pid): kill(pid, 0)=\(killResult), errno=\(err), gameRunning=\(gameRunning)")
            } else {
                print("   [DEBUG] Game PID \(pid): kill(pid, 0)=\(killResult), gameRunning=\(gameRunning)")
            }
        }
        
        let finalResult = wrapperRunning || gameRunning
        print("   [DEBUG] Final isRunning result: \(finalResult) (wrapper=\(wrapperRunning), game=\(gameRunning))")
        
        return finalResult
    }
    
    /// Force terminate app and game engine child processes
    static func forceQuit(_ app: NSRunningApplication, gameEngine: String = "") {
        print("⚠️  Force quitting game...")
        
        // Terminate main app
        app.forceTerminate()
        
        // Also kill engine-specific processes
        if gameEngine.lowercased().contains("wine") {
            let killWine = Process()
            killWine.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killWine.arguments = ["-9", "-f", "wine"]
            try? killWine.run()
            killWine.waitUntilExit()
        } else if gameEngine.lowercased().contains("scummvm") {
            let killScummVM = Process()
            killScummVM.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killScummVM.arguments = ["-9", "scummvm"]
            try? killScummVM.run()
            killScummVM.waitUntilExit()
        }
    }
    
    /// Wait for app to terminate (handles child process engines)
    static func waitForTermination(_ app: NSRunningApplication, gamePid: Int32?, timeout: TimeInterval) -> Bool {
        let startTime = Date()
        var lastPrintTime = Date()
        
        // Print initial info about what we're waiting for
        if let gamePid = gamePid {
            print("   Waiting for game process (PID: \(gamePid)) and wrapper (PID: \(app.processIdentifier)) to exit...")
        } else {
            print("   Waiting for wrapper process (PID: \(app.processIdentifier)) to exit...")
        }
        
        while Date().timeIntervalSince(startTime) < timeout {
            if !isRunning(app, gamePid: gamePid) {
                let elapsed = Date().timeIntervalSince(startTime)
                print("   ✓ Process exited after \(String(format: "%.1f", elapsed))s")
                return true
            }
            
            // Print status every 2 seconds
            if Date().timeIntervalSince(lastPrintTime) >= 2.0 {
                let elapsed = Date().timeIntervalSince(startTime)
                
                // Check which processes are still running - use fresh lookups
                let wrapperRunning = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == app.processIdentifier })?.isTerminated == false
                let gamePidRunning = gamePid != nil && (kill(gamePid!, 0) == 0)
                
                var statusParts: [String] = []
                if wrapperRunning {
                    statusParts.append("wrapper (PID: \(app.processIdentifier))")
                }
                if gamePidRunning, let pid = gamePid {
                    statusParts.append("game (PID: \(pid))")
                }
                
                let statusString = statusParts.joined(separator: ", ")
                print("   [\(String(format: "%.1f", elapsed))s] Still running: \(statusString)")
                lastPrintTime = Date()
            }
            
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        print("   ✗ Timeout after \(Int(timeout))s waiting for process to exit")
        return false
    }
}
