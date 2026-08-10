//
//  DebugSettings.swift
//  SecondChance
//
//  Debug settings for development and testing

import Foundation
import Combine

/// Singleton class to manage debug settings
class DebugSettings: ObservableObject {
    static let shared = DebugSettings()
    
    @Published var skipInstaller: Bool
    @Published var debugMode: Bool
    @Published var showUnsupportedInstallOptions: Bool = false
    
    private init() {
        // Check for command line flags
        let arguments = ProcessInfo.processInfo.arguments
        self.skipInstaller = arguments.contains("--skip-installer")
        self.debugMode = arguments.contains("--debug")
    }
    
    /// Reset all debug settings to defaults
    func resetToDefaults() {
        skipInstaller = false
        debugMode = false
        showUnsupportedInstallOptions = false
    }
}
