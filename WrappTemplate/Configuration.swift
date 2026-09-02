//
//  Configuration.swift
//  WrappTemplate
//
//  Configuration management for Nancy Drew game wrappers

import Foundation
import Logging

private nonisolated let configLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Configuration")

// MARK: - Game Configuration

struct GameConfig {
    let appPath: URL
    let winePrefix: URL
    let gameExePath: String
    let gameInstallerDir: String
    let gameEngine: String
    let steamGameId: String?
    let gameTitle: String
    let gameSlug: String
    let bundleId: String
    let appSupportPath: URL
}

// MARK: - Plist Reading

func readPlist(at path: URL, key: String) -> String? {
    guard let data = try? Data(contentsOf: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return nil
    }
    
    // Support nested keys using dot notation (e.g., "Parent.Child")
    let keys = key.split(separator: ".").map(String.init)
    var current: Any? = plist
    
    for key in keys {
        guard let dict = current as? [String: Any] else {
            return nil
        }
        current = dict[key]
    }
    
    // Convert result to string
    if let string = current as? String {
        return string
    } else if let number = current as? NSNumber {
        return number.stringValue
    } else if let bool = current as? Bool {
        return bool ? "true" : "false"
    }
    
    return nil
}

func getWinePrefix(appPath: URL, bundleId: String) -> URL {
    let originalPrefixPath = appPath.appendingPathComponent("Contents/SharedSupport/prefix")
    let fileManager = FileManager.default
    
    // Test if prefix is writable
    let testFile = originalPrefixPath.appendingPathComponent(".write_test")
    let isPrefixReadOnly = !fileManager.isWritableFile(atPath: originalPrefixPath.path) || 
                           !fileManager.createFile(atPath: testFile.path, contents: Data(), attributes: nil)
    
    if !isPrefixReadOnly {
        // Clean up test file and return original prefix
        try? fileManager.removeItem(at: testFile)
        return originalPrefixPath
    }
    
    // Prefix is read-only, set up cached copy
    configLogger.notice("[Wine] Prefix is read-only, copying to cache directory...")
    
    let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    var cachedPrefixPath = cacheDir
        .appendingPathComponent(bundleId)
        .appendingPathComponent("prefix")
    
    // Try to remove existing cache if present
    if fileManager.fileExists(atPath: cachedPrefixPath.path) {
        configLogger.notice("[Wine] Removing existing cached prefix...")
        do {
            try fileManager.removeItem(at: cachedPrefixPath)
        } catch {
            // If removal fails (e.g., permissions issues), use a new path with timestamp
            configLogger.notice("[Wine] Could not remove existing cache, using timestamped path instead")
            let timestamp = Int(Date().timeIntervalSince1970)
            cachedPrefixPath = cacheDir
                .appendingPathComponent(bundleId)
                .appendingPathComponent("prefix-\(timestamp)")
        }
    }
    
    // Create cache directory
    try? fileManager.createDirectory(at: cachedPrefixPath, withIntermediateDirectories: true)
    
    // Copy all contents except drive_c
    do {
        let prefixContents = try fileManager.contentsOfDirectory(atPath: originalPrefixPath.path)
        
        for item in prefixContents {
            if item == "drive_c" {
                continue  // Skip drive_c for now, will handle separately
            }
            
            let sourcePath = originalPrefixPath.appendingPathComponent(item)
            let destPath = cachedPrefixPath.appendingPathComponent(item)
            
            // Use cp -R to copy without preserving BSD flags (uchg)
            // Note: Not using -p flag so it won't preserve flags
            let cpProcess = Process()
            cpProcess.executableURL = URL(fileURLWithPath: "/bin/cp")
            cpProcess.arguments = ["-R", sourcePath.path, destPath.path]
            try cpProcess.run()
            cpProcess.waitUntilExit()
        }
        
        configLogger.notice("[Wine] Copied prefix contents to cache (excluding drive_c)")
        
        // Recreate drive_c structure with selective copying/symlinking
        let originalDriveCPath = originalPrefixPath.appendingPathComponent("drive_c")
        let cachedDriveCPath = cachedPrefixPath.appendingPathComponent("drive_c")
        
        func recreateDriveCStructure(sourceDir: URL, destDir: URL) throws {
            // Create destination directory
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            // Get contents of source directory
            let contents = try fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            
            for sourceItem in contents {
                let destItem = destDir.appendingPathComponent(sourceItem.lastPathComponent)
                
                // Check if it's a symlink
                let resourceValues = try sourceItem.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                
                if resourceValues.isSymbolicLink == true {
                    // Copy symlinks as-is
                    let symlinkDest = try fileManager.destinationOfSymbolicLink(atPath: sourceItem.path)
                    try fileManager.createSymbolicLink(atPath: destItem.path, withDestinationPath: symlinkDest)
                    
                } else if resourceValues.isDirectory == true {
                    // Recursively handle directories
                    try recreateDriveCStructure(sourceDir: sourceItem, destDir: destItem)
                    
                } else {
                    // Handle regular files based on size
                    let fileSize = resourceValues.fileSize ?? 0
                    
                    if fileSize < 10_000 {
                        // Copy small files (< 10KB)
                        try fileManager.copyItem(at: sourceItem, to: destItem)
                    } else {
                        // Create symlink for large files (>= 10KB)
                        try fileManager.createSymbolicLink(at: destItem, withDestinationURL: sourceItem)
                    }
                }
            }
        }
        
        try recreateDriveCStructure(sourceDir: originalDriveCPath, destDir: cachedDriveCPath)
        
        configLogger.notice("[Wine] Recreated drive_c structure with selective copying/symlinking")
        
        return cachedPrefixPath
        
    } catch {
        configLogger.critical("⛔️ [Wine] Error setting up cached prefix: \(error)")
        configLogger.notice("[Wine] Falling back to original prefix")
        return originalPrefixPath
    }
}

func loadConfig(customWinePrefix: URL? = nil) -> GameConfig? {
    // Get app path
    guard let executablePath = ProcessInfo.processInfo.arguments.first else {
        configLogger.critical("ERROR: Could not determine executable path")
        return nil
    }
    
    let executableURL = URL(fileURLWithPath: executablePath)
    let appPath = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    
    let settingsPlistPath = appPath.appendingPathComponent("Contents/Resources/AppSettings.plist")
    let infoPlistPath = appPath.appendingPathComponent("Contents/Info.plist")
    
    // Read plists
    guard let gameExePath = readPlist(at: settingsPlistPath, key: "GameExePath"),
          let gameInstallerDir = readPlist(at: settingsPlistPath, key: "GameInstallerDir"),
          let gameEngine = readPlist(at: settingsPlistPath, key: "GameEngine"),
          let gameTitle = readPlist(at: infoPlistPath, key: "CFBundleName"),
          let bundleId = readPlist(at: infoPlistPath, key: "CFBundleIdentifier") else {
        configLogger.critical("ERROR: Could not read required configuration from plists")
        return nil
    }
    
    let steamGameId = readPlist(at: settingsPlistPath, key: "SteamGameId")
    let gameSlug = readPlist(at: settingsPlistPath, key: "GameSlug") ?? "unknown"
    
    let winePrefix = customWinePrefix ?? appPath.appendingPathComponent("Contents/SharedSupport/prefix")
    
    // Setup app support directory
    let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(bundleId)
    
    try? FileManager.default.createDirectory(at: appSupportPath, withIntermediateDirectories: true)
    
    return GameConfig(
        appPath: appPath,
        winePrefix: winePrefix,
        gameExePath: gameExePath,
        gameInstallerDir: gameInstallerDir,
        gameEngine: gameEngine,
        steamGameId: steamGameId,
        gameTitle: gameTitle,
        gameSlug: gameSlug,
        bundleId: bundleId,
        appSupportPath: appSupportPath
    )
}
