//
//  CacheManager.swift
//  SecondChance
//
//  Manages caching and restoration of wrapper states for debugging

import Foundation

/// Manages the caching system for wrapper creation stages
class CacheManager {
    static let shared = CacheManager()
    
    private let fileManager = FileManager.default
    private var cacheDirectory: URL
    
    private init() {
        // Use a temporary directory for caches
        let tempDir = fileManager.temporaryDirectory
        cacheDirectory = tempDir.appendingPathComponent("SecondChance/wrapper-cache")
        
        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Configure which stages should be restored from cache (for development)
    var stagesToRestore: Set<CacheStage> = []
    
    /// Enable or disable caching entirely
    var cachingEnabled: Bool = false
    
    // MARK: - Caching Operations
    
    /// Save a wrapper state at a specific stage
    func saveCache(
        wrapperPath: URL,
        stage: CacheStage,
        gameSlug: String? = nil,
        installationType: InstallationType? = nil,
        gameExePath: String? = nil
    ) throws {
        guard cachingEnabled else { return }
        
        let stageDir = cacheDirectory.appendingPathComponent(stage.rawValue)
        
        // Remove existing cache for this stage
        try? fileManager.removeItem(at: stageDir)
        
        // Create stage directory
        try fileManager.createDirectory(at: stageDir, withIntermediateDirectories: true)
        
        // Copy wrapper
        let cachedWrapperPath = stageDir.appendingPathComponent("wrapper.app")
        try fileManager.copyItem(at: wrapperPath, to: cachedWrapperPath)
        
        // Save metadata
        let metadata = CacheMetadata(
            stage: stage,
            gameSlug: gameSlug,
            installationType: installationType,
            gameExePath: gameExePath
        )
        let metadataPath = stageDir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataPath)
        
        print("✓ Cached wrapper at stage: \(stage.displayName)")
    }
    
    /// Attempt to restore a wrapper from cache at a specific stage
    func restoreCache(stage: CacheStage, to destinationPath: URL) throws -> CacheMetadata? {
        guard cachingEnabled, stagesToRestore.contains(stage) else {
            return nil
        }
        
        let stageDir = cacheDirectory.appendingPathComponent(stage.rawValue)
        let cachedWrapperPath = stageDir.appendingPathComponent("wrapper.app")
        let metadataPath = stageDir.appendingPathComponent("metadata.json")
        
        // Check if cache exists
        guard fileManager.fileExists(atPath: cachedWrapperPath.path),
              fileManager.fileExists(atPath: metadataPath.path) else {
            return nil
        }
        
        // Load metadata
        let data = try Data(contentsOf: metadataPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(CacheMetadata.self, from: data)
        
        // Remove destination if it exists
        try? fileManager.removeItem(at: destinationPath)
        
        // Copy cached wrapper to destination
        try fileManager.copyItem(at: cachedWrapperPath, to: destinationPath)
        
        print("✓ Restored wrapper from cache: \(stage.displayName)")
        return metadata
    }
    
    /// Clear all cached wrappers
    func clearAllCaches() throws {
        try fileManager.removeItem(at: cacheDirectory)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        print("✓ Cleared all caches")
    }
    
    /// Clear cache for a specific stage
    func clearCache(for stage: CacheStage) throws {
        let stageDir = cacheDirectory.appendingPathComponent(stage.rawValue)
        try fileManager.removeItem(at: stageDir)
        print("✓ Cleared cache for: \(stage.displayName)")
    }
    
    /// List all available cached stages
    func availableCaches() -> [(stage: CacheStage, metadata: CacheMetadata)] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        
        var results: [(CacheStage, CacheMetadata)] = []
        
        for dir in contents {
            guard let stage = CacheStage(rawValue: dir.lastPathComponent) else {
                continue
            }
            
            let metadataPath = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataPath),
                  let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) else {
                continue
            }
            
            results.append((stage, metadata))
        }
        
        return results.sorted(by: { $0.0.rawValue < $1.0.rawValue })
    }
    
    /// Get the size of all caches
    func totalCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory,
                  !isDirectory,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }
        
        return totalSize
    }
}
