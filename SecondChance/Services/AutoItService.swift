//
//  AutoItService.swift
//  SecondChance
//
//  Provides centralized access to bundled AutoIt for automating installer dialogs

import Foundation
import Logging

/// Service for running AutoIt scripts to automate installation dialogs
class AutoItService {
    static let shared = AutoItService()
    
    let autoitPath: String
    let autoitDir: URL
    private let fileManager = FileManager.default
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.AutoItService")
    
    private init() {
        // Get path to AutoIt bundled in app
        let bundleResourcePath = Bundle.main.resourceURL?.appendingPathComponent("autoit")
        logger.notice("🔍 Looking for bundled AutoIt at: \(bundleResourcePath?.path ?? "nil")")
        
        if let bundlePath = bundleResourcePath, fileManager.fileExists(atPath: bundlePath.path) {
            autoitDir = bundlePath
            // AutoIt3.exe is the main executable
            autoitPath = bundlePath.appendingPathComponent("AutoIt3.exe").path
            logger.notice("✅ Found bundled AutoIt at: \(bundlePath.path)")
        } else {
            logger.critical("❌ ERROR: Bundled AutoIt not found!")
            logger.notice("   Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")")
            logger.notice("   Expected at: \(bundleResourcePath?.path ?? "nil")")
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
