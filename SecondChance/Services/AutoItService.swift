//
//  AutoItService.swift
//  SecondChance
//
//  Provides centralized access to bundled AutoIt for automating installer dialogs

import Foundation

/// Service for running AutoIt scripts to automate installation dialogs
class AutoItService {
    static let shared = AutoItService()
    
    let autoitPath: String
    let autoitDir: URL
    private let fileManager = FileManager.default
    
    private init() {
        // Get path to AutoIt bundled in app
        let bundleResourcePath = Bundle.main.resourceURL?.appendingPathComponent("autoit")
        print("🔍 Looking for bundled AutoIt at: \(bundleResourcePath?.path ?? "nil")")
        
        if let bundlePath = bundleResourcePath, fileManager.fileExists(atPath: bundlePath.path) {
            autoitDir = bundlePath
            // AutoIt3.exe is the main executable
            autoitPath = bundlePath.appendingPathComponent("AutoIt3.exe").path
            print("✅ Found bundled AutoIt at: \(bundlePath.path)")
        } else {
            print("❌ ERROR: Bundled AutoIt not found!")
            print("   Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")")
            print("   Expected at: \(bundleResourcePath?.path ?? "nil")")
            // Use a non-existent path that will fail explicitly
            autoitPath = "/AUTOIT_NOT_BUNDLED"
            autoitDir = URL(fileURLWithPath: "/AUTOIT_NOT_BUNDLED")
        }
    }
    
    /// Check if AutoIt is available
    var isAvailable: Bool {
        return fileManager.fileExists(atPath: autoitPath)
    }
    
    /// Get the path to the AutoIt directory
    var directory: URL {
        return autoitDir
    }
}
