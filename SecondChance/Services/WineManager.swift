//
//  WineManager.swift
//  SecondChance
//
//  Manages Wine environment and execution

import Foundation
import os
import AppKit

// Note: WineEnvironment is defined in this same module

/// Manages Wine environment setup and execution
class WineManager {
    static let shared = WineManager()
    
    private let fileManager = FileManager.default
    private let prefixCacheDir: URL
    private let logger = Logger(subsystem: "com.secondchance", category: "WineManager")
    
    private init() {
        // Set up prefix cache directory in user's Caches (persists between runs)
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/wine-prefix-cache")
        prefixCacheDir = cacheDir
        try? fileManager.createDirectory(at: prefixCacheDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Wine Prefix Management
    
    /// Get the build identifier for cache invalidation
    private func getBuildIdentifier() -> String {
        #if DEBUG
        // In debug mode, use a static identifier so cache persists across builds
        return "dev"
        #else
        // In release mode, use the bundle version to invalidate cache on updates
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return version
        }
        return "unknown"
        #endif
    }
    
    /// Get the cached Wine prefix if available and valid
    private func getCachedPrefix() -> URL? {
        let buildId = getBuildIdentifier()
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)
        let cachedPrefix = cachedPrefixDir.appendingPathComponent("prefix")
        
        // Check if cached prefix exists and is a directory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cachedPrefix.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        
        // Verify it has the expected structure
        let driveCPath = cachedPrefix.appendingPathComponent("drive_c")
        var isDriveCDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: driveCPath.path, isDirectory: &isDriveCDirectory),
              isDriveCDirectory.boolValue else {
            return nil
        }
        
        return cachedPrefix
    }
    
    /// Save Wine prefix to cache
    private func cachePrefix(from sourcePath: URL) throws {
        let buildId = getBuildIdentifier()
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)
        let cachedPrefix = cachedPrefixDir.appendingPathComponent("prefix")
        
        logger.notice("Caching Wine prefix for build: \(buildId, privacy: .public)...")
        
        // Remove old cache for this build if it exists
        try? fileManager.removeItem(at: cachedPrefixDir)
        
        // Create cache directory
        try fileManager.createDirectory(at: cachedPrefixDir, withIntermediateDirectories: true)
        
        // Copy prefix to cache
        try fileManager.copyItem(at: sourcePath, to: cachedPrefix)
        
        logger.notice("✓ Cached Wine prefix for build: \(buildId, privacy: .public)")
    }
    
    /// Clear all cached Wine prefixes
    func clearCache() throws {
        if fileManager.fileExists(atPath: prefixCacheDir.path) {
            try fileManager.removeItem(at: prefixCacheDir)
            logger.notice("✓ Cleared Wine prefix cache")
        } else {
            logger.notice("✓ Wine prefix cache is already empty")
        }
    }
    
    /// Create a new Wine prefix at the specified path
    func createWinePrefix(at wrapperPath: URL) async throws {
        let prefixPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix")
        
        // Check if we have a cached prefix
        if let cachedPrefix = getCachedPrefix() {
            let buildId = getBuildIdentifier()
            logger.notice("✓ Using cached Wine prefix (build: \(buildId, privacy: .public))")
            
            // Copy cached prefix to wrapper
            try? fileManager.removeItem(at: prefixPath)
            try fileManager.copyItem(at: cachedPrefix, to: prefixPath)
            
            return
        }
        
        // Run wineboot to initialize (wineboot is a Windows program, so run it through wine)
        try await runWine(
            at: wrapperPath,
            executable: "wine",
            arguments: ["wineboot", "-u"]
        )
            
        // Wait for wineserver to finish
        try await waitForWineToExit(at: wrapperPath)
        
        // Install cnc-ddraw for better DirectDraw compatibility
        Task { await EventBus.app.publishInstallation(.progress(.settingUpWrapper(substep: "Installing cnc-ddraw"))) }
        try await installWinetrick("cnc_ddraw", at: wrapperPath)
        
        // Configure cnc-ddraw to maintain aspect ratio
        let ddrawIniPath = prefixPath.appendingPathComponent("drive_c/windows/syswow64/ddraw.ini")
            if fileManager.fileExists(atPath: ddrawIniPath.path) {
                if let contents = try? String(contentsOf: ddrawIniPath, encoding: .utf8) {
                    let updated = contents.replacingOccurrences(of: "maintas=false", with: "maintas=true")
                    try? updated.write(to: ddrawIniPath, atomically: true, encoding: .utf8)
                    logger.notice("✓ Configured cnc-ddraw to maintain aspect ratio")
                }
            }
        
        // Install isolate_home to remove unnecessary mounts
        Task { await EventBus.app.publishInstallation(.progress(.settingUpWrapper(substep: "Configuring drive mounts"))) }
        try await installWinetrick("isolate_home", at: wrapperPath)
        
        // Remove all drive mounts and recreate only the ones we need
        let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
            if let existingMounts = try? fileManager.contentsOfDirectory(atPath: dosdevicesPath.path) {
                for mount in existingMounts {
                    try? fileManager.removeItem(at: dosdevicesPath.appendingPathComponent(mount))
                }
            }
            
            // Create A: drive - This will be used for saving game data and hopefully will be overridden on game launch
            // to point to a user's Application Support directory instead but in case the game is started in a read-only
            // context we point it to a dir we can write. Then at launch we add a symlink at that location to point to
            // Application Support dir.
            let uuid = UUID().uuidString
            try fileManager.createSymbolicLink(
                atPath: dosdevicesPath.appendingPathComponent("a:").path,
                withDestinationPath: "/tmp/second-chance-nancy-drew-\(uuid)" 
            )
            
            // Create C: drive (points to drive_c)
            try fileManager.createSymbolicLink(
                atPath: dosdevicesPath.appendingPathComponent("c:").path,
                withDestinationPath: "../drive_c"
            )
            
            // Create Z: drive (points to root filesystem)
            try fileManager.createSymbolicLink(
                atPath: dosdevicesPath.appendingPathComponent("z:").path,
                withDestinationPath: "/"
            )
            
            // Create dummy files for d: through y: to prevent Wine from auto-mounting
            for letter in "bdefghijklmnopqrstuvwxy" {
                let dummyPath = dosdevicesPath.appendingPathComponent("\(letter):")
                fileManager.createFile(atPath: dummyPath.path, contents: nil)
            }
            
        // Ensure Wine server is fully shut down before caching
        // This ensures all registry changes and file writes are flushed to disk
        try await waitForWineToExit(at: wrapperPath)
        
        // Cache the prefix for future use
        try cachePrefix(from: prefixPath)
    }    
    /// Mount a directory as a drive in Wine
    func mountDirectory(
        _ sourcePath: String,
        asDrive driveLetter: String,
        type driveType: String = "hd",
        in wrapperPath: URL
    ) async throws {
        let prefixPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix")
        let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
        
        // Create symlink for drive
        let driveLink = dosdevicesPath.appendingPathComponent("\(driveLetter):")
        
        // Remove existing link if present
        try? fileManager.removeItem(at: driveLink)
        
        // Create new symlink using the path directly (preserves relative paths)
        try fileManager.createSymbolicLink(
            atPath: driveLink.path,
            withDestinationPath: sourcePath
        )
        
        // Set drive type in Wine registry if specified
        if !driveType.isEmpty {
            logger.notice("Setting drive \(driveLetter, privacy: .public): type to \(driveType, privacy: .public) in Wine registry")
            try await runWine(
                at: wrapperPath,
                executable: "wine",
                arguments: [
                    "reg", "add",
                    "HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives",
                    "/v", "\(driveLetter):",
                    "/t", "REG_SZ",
                    "/d", driveType,
                    "/f"
                ]
            )
        }
    }
    
    // MARK: - Wine Execution
    
    /// Run a program with Wine
    func runWine(
        at wrapperPath: URL,
        executable: String,
        arguments: [String] = []
    ) async throws {
        let wine = WineEnvironment(appPath: wrapperPath)
        try await wine.runWine(executable: executable, arguments: arguments)
    }
    
    /// Run a Windows executable through Wine.
    ///
    /// Returns the Wine process exit code. A non-zero exit code is logged as a
    /// warning but does NOT throw — only launch failures (e.g. Wine not found,
    /// process could not start) throw. Callers that need to treat a non-zero
    /// exit as an error should inspect the returned code.
    @discardableResult
    func runWindowsExecutable(
        at wrapperPath: URL,
        exePath: String,
        arguments: [String] = []
    ) async throws -> Int32 {
        let args = [exePath] + arguments
        return try await runWineReturningExitCode(
            at: wrapperPath,
            executable: "wine",
            arguments: args
        )
    }
    
    /// Run executable with wine start /wait.
    ///
    /// Returns the Wine process exit code. A non-zero exit code is logged as a
    /// warning but does NOT throw — only launch failures throw. See
    /// `runWindowsExecutable` for details.
    @discardableResult
    func runWindowsExecutableWithStart(
        at wrapperPath: URL,
        exePath: String,
        arguments: [String] = []
    ) async throws -> Int32 {
        let wine = WineEnvironment(appPath: wrapperPath)
        do {
            try await wine.runWindowsExecutableWithStartAsync(exePath: exePath, arguments: arguments)
            return 0
        } catch let WineError.executionFailed(exitCode) {
            logger.error("⚠️  Warning: \(exePath, privacy: .public) exited with non-zero code: \(exitCode, privacy: .public)")
            return exitCode
        }
    }
    
    /// Run a Wine program and return its exit code.
    ///
    /// Non-zero exit codes are logged as a warning and returned (not thrown);
    /// only genuine launch failures throw. Shared helper for
    /// `runWindowsExecutable` and friends.
    private func runWineReturningExitCode(
        at wrapperPath: URL,
        executable: String,
        arguments: [String] = []
    ) async throws -> Int32 {
        do {
            try await runWine(at: wrapperPath, executable: executable, arguments: arguments)
            return 0
        } catch let WineError.executionFailed(exitCode) {
            logger.error("⚠️  Warning: \(executable, privacy: .public) exited with non-zero code: \(exitCode, privacy: .public)")
            return exitCode
        }
    }
    
    /// Wait for Wine server to exit
    func waitForWineToExit(at wrapperPath: URL) async throws {
        try await runWine(at: wrapperPath, executable: "wineserver", arguments: ["-w"])
    }
    
    /// Start Wine server manually (prevents automatic shutdown)
    func startWineServer(at wrapperPath: URL) throws {
        let wine = WineEnvironment(appPath: wrapperPath)
        let wineserverPath = wine.wineBinDir.appendingPathComponent("wineserver")
        
        let process = Process()
        process.executableURL = wineserverPath
        process.arguments = ["-p"]  // Persistent mode
        process.environment = wine.environmentVariables()
        
        try process.run()
        process.waitUntilExit()
        
        logger.notice("Wine server started in persistent mode")
    }
    
    /// Install a winetrick
    func installWinetrick(_ name: String, at wrapperPath: URL) async throws {
        // Check if winetricks is bundled
        guard let winetricksPath = Bundle.main.path(forResource: "winetricks", ofType: nil) else {
            throw WineError.winetricksNotFound
        }
        
        let wine = WineEnvironment(appPath: wrapperPath)
        
        // Run in detached task to avoid blocking
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [winetricksPath, "--unattended", name]
            process.environment = wine.environmentVariables()
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                // Log output
                let outputHandle = outputPipe.fileHandleForReading
                let errorHandle = errorPipe.fileHandleForReading
                
                if let output = String(data: outputHandle.readDataToEndOfFile(), encoding: .utf8), !output.isEmpty {
                    self.logger.notice("Winetricks output: \(output, privacy: .public)")
                }
                
                if let error = String(data: errorHandle.readDataToEndOfFile(), encoding: .utf8), !error.isEmpty {
                    self.logger.notice("Winetricks error: \(error, privacy: .public)")
                }
                
                if process.terminationStatus != 0 {
                    continuation.resume(throwing: WineError.executionFailed(exitCode: process.terminationStatus))
                    return
                }
                
                self.logger.notice("✓ Successfully installed \(name, privacy: .public)")
                continuation.resume()
            } catch {
                self.logger.notice("Failed to install winetrick \(name, privacy: .public): \(error, privacy: .public)")
                continuation.resume(throwing: error)
            }
            }
        }
    }
}

