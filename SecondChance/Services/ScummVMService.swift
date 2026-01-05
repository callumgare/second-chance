//
//  ScummVMService.swift
//  SecondChance
//
//  Provides centralized access to bundled ScummVM for running classic Nancy Drew games

import Foundation

/// Service for accessing bundled ScummVM runtime
class ScummVMService {
    static let shared = ScummVMService()
    
    let scummvmExecutablePath: String
    let scummvmDir: URL
    let scummvmIniPath: String
    private let fileManager = FileManager.default
    
    private init() {
        // Get path to ScummVM bundled in app
        let bundleResourcePath = Bundle.main.resourceURL?.appendingPathComponent("scummvm")
        print("🔍 Looking for bundled ScummVM at: \(bundleResourcePath?.path ?? "nil")")
        
        if let bundlePath = bundleResourcePath, fileManager.fileExists(atPath: bundlePath.path) {
            scummvmDir = bundlePath
            // scummvm binary is in Resources/
            scummvmExecutablePath = bundlePath.appendingPathComponent("Resources/scummvm").path
            scummvmIniPath = bundlePath.appendingPathComponent("scummvm.ini").path
            print("✅ Found bundled ScummVM at: \(bundlePath.path)")
        } else {
            print("❌ ERROR: Bundled ScummVM not found!")
            print("   Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")")
            print("   Expected at: \(bundleResourcePath?.path ?? "nil")")
            // Use a non-existent path that will fail explicitly
            scummvmExecutablePath = "/SCUMMVM_NOT_BUNDLED"
            scummvmIniPath = "/SCUMMVM_INI_NOT_BUNDLED"
            scummvmDir = URL(fileURLWithPath: "/SCUMMVM_NOT_BUNDLED")
        }
    }
    
    /// Check if ScummVM is available
    var isAvailable: Bool {
        return fileManager.fileExists(atPath: scummvmExecutablePath)
    }
    
    /// Get the path to the ScummVM directory
    var directory: URL {
        return scummvmDir
    }
}
