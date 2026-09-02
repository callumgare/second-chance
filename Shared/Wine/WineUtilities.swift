//
//  WineUtilities.swift
//  Shared Wine utilities
//
//  Minimal Wine utilities that can be used by both WrappTemplate and SecondChance
//  without requiring SecondChance-specific dependencies

import Foundation
import Logging

private nonisolated let wineUtilitiesLogger = Logger(label: "au.gare.callum.second-chance.Shared.WineUtilities")

/// Utility functions for Wine operations that don't require progress reporting
class WineUtilities {
    
    /// Wait for Wine server to stop with escalating force
    /// This is a standalone utility that can be used by WrappTemplate without needing WineManager
    static func waitTillWineserverStopped(at wrappPath: URL, customPrefixDir: URL? = nil) {
        let wine = WineEnvironment(appPath: wrappPath, customPrefixDir: customPrefixDir)
        
        // Try graceful shutdown with -w (wait for processes to exit)
        wineUtilitiesLogger.notice("[Wine Cleanup] Running wineserver -w (waiting for processes to exit cleanly)...")
        let waitProcess = Process()
        waitProcess.executableURL = URL(fileURLWithPath: wine.wineBinDir.appendingPathComponent("wineserver").path)
        waitProcess.arguments = ["-w"]
        waitProcess.environment = wine.environmentVariables()
        
        do {
            try waitProcess.run()
            
            // Wait up to 5 seconds for graceful shutdown
            var elapsed = 0.0
            let checkInterval = 0.1
            while waitProcess.isRunning && elapsed < 5.0 {
                Thread.sleep(forTimeInterval: checkInterval)
                elapsed += checkInterval
            }
            
            if waitProcess.isRunning {
                wineUtilitiesLogger.error("[Wine Cleanup] Graceful shutdown timed out after 5 seconds")
                waitProcess.terminate()
                
                // Force termination with -k (SIGTERM) - don't wait for it
                wineUtilitiesLogger.notice("[Wine Cleanup] Running wineserver -k (sending SIGTERM)...")
                let killProcess = Process()
                killProcess.executableURL = URL(fileURLWithPath: wine.wineBinDir.appendingPathComponent("wineserver").path)
                killProcess.arguments = ["-k"]
                killProcess.environment = wine.environmentVariables()
                try killProcess.run()
                
                // Wait up to 5 more seconds for processes to exit
                Thread.sleep(forTimeInterval: 5.0)
                
                // Force kill with -k9 (SIGKILL) regardless of whether -k finished
                wineUtilitiesLogger.notice("[Wine Cleanup] Running wineserver -k9 (sending SIGKILL)...")
                let killForceProcess = Process()
                killForceProcess.executableURL = URL(fileURLWithPath: wine.wineBinDir.appendingPathComponent("wineserver").path)
                killForceProcess.arguments = ["-k9"]
                killForceProcess.environment = wine.environmentVariables()
                try killForceProcess.run()
                killForceProcess.waitUntilExit()
            } else {
                wineUtilitiesLogger.notice("[Wine Cleanup] Processes exited cleanly")
            }
        } catch {
            wineUtilitiesLogger.error("[Wine Cleanup] Error during wineserver cleanup: \(error)")
        }
    }
}
