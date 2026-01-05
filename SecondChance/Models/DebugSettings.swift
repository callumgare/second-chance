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
    
    @Published var skipInstaller: Bool {
        didSet {
            UserDefaults.standard.set(skipInstaller, forKey: "DebugSettings.skipInstaller")
        }
    }
    
    private init() {
        // Load saved settings
        self.skipInstaller = UserDefaults.standard.bool(forKey: "DebugSettings.skipInstaller")
    }
    
    /// Reset all debug settings to defaults
    func resetToDefaults() {
        skipInstaller = false
    }
}
