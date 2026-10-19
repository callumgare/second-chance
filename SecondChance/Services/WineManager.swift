//
//  WineManager.swift
//  SecondChance
//
//  Manages Wine environment and execution

import Foundation
import Logging
import AppKit

// Note: WineEnvironment is defined in this same module

/// Manages Wine environment setup and execution
class WineManager {
    static let shared = WineManager()
    
    private let fileManager = FileManager.default
    private let prefixCacheDir: URL
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WineManager")
    
    private init() {
        // Set up prefix cache directory in user's Caches (persists between runs)
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/wine-prefix-cache")
        prefixCacheDir = cacheDir
        try? fileManager.createDirectory(at: prefixCacheDir, withIntermediateDirectories: true)
    }
    
    // MARK: - Wine Prefix Management
    
    /// The prefix cache key for a wrapp: the build, plus the Wine engine it
    /// carries. A prefix is only reused by the engine that created it, so a
    /// Wine upgrade starts a fresh one without anyone clearing the cache.
    private func getBuildIdentifier(for wrappPath: URL) -> String {
        #if DEBUG
        // In debug mode the build part is static, so the cache persists across builds
        let build = "dev"
        #else
        // In release mode, use the bundle version to invalidate cache on updates
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        #endif
        let versionFile = wrappPath.appendingPathComponent("Contents/SharedSupport/wine/version")
        let engine: String?
        do {
            engine = try String(contentsOf: versionFile, encoding: .utf8)
        } catch {
            logger.warning("Couldn't read the Wine engine's version from \(versionFile.path), so the prefix cache isn't keyed on it: \(error.localizedDescription)")
            engine = nil
        }
        return Self.prefixCacheKey(build: build, engineVersion: engine)
    }

    /// `build`, then the engine's version as a path-safe slug:
    /// "wine sikarugir 10.0 (revision 8)" → "dev-wine-sikarugir-10-0-revision-8".
    static func prefixCacheKey(build: String, engineVersion: String?) -> String {
        let slug = (engineVersion ?? "")
            .lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
        return slug.isEmpty ? build : "\(build)-\(slug)"
    }
    
    /// Get the cached Wine prefix if available and valid
    private func getCachedPrefix(buildId: String) -> URL? {
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
    private func cachePrefix(from sourcePath: URL, buildId: String) throws {
        let cachedPrefixDir = prefixCacheDir.appendingPathComponent(buildId)
        let cachedPrefix = cachedPrefixDir.appendingPathComponent("prefix")
        
        logger.notice("Caching Wine prefix for build: \(buildId)...")
        
        // Remove old cache for this build if it exists, and every other build's:
        // a prefix only serves the build and engine that made it, and each is
        // hundreds of MB.
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: prefixCacheDir, includingPropertiesForKeys: nil)
        } catch {
            logger.warning("Couldn't list the Wine prefix cache to remove old prefixes: \(error.localizedDescription)")
            entries = []
        }
        for entry in entries {
            do {
                try fileManager.removeItem(at: entry)
                if entry.lastPathComponent != buildId {
                    logger.notice("Removed the cached Wine prefix for build \(entry.lastPathComponent)")
                }
            } catch {
                logger.warning("Couldn't remove cached Wine prefix \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        // Create cache directory
        try fileManager.createDirectory(at: cachedPrefixDir, withIntermediateDirectories: true)
        
        // Copy prefix to cache
        try fileManager.copyItem(at: sourcePath, to: cachedPrefix)
        
        logger.notice("✓ Cached Wine prefix for build: \(buildId)")
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
    func createWinePrefix(at wrappPath: URL) async throws {
        let prefixPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix")
        
        // Check if we have a cached prefix
        let buildId = getBuildIdentifier(for: wrappPath)
        if let cachedPrefix = getCachedPrefix(buildId: buildId) {
            logger.notice("✓ Using cached Wine prefix (build: \(buildId))")
            
            // Copy cached prefix to wrapp
            try? fileManager.removeItem(at: prefixPath)
            try fileManager.copyItem(at: cachedPrefix, to: prefixPath)
            
            return
        }
        
        // Run wineboot to initialize (wineboot is a Windows program, so run it through wine)
        try await runWine(
            at: wrappPath,
            executable: "wine",
            arguments: ["wineboot", "-u"]
        )
            
        // Wait for wineserver to finish
        try await waitForWineToExit(at: wrappPath)
        
        // Install cnc-ddraw for better DirectDraw compatibility
        Task { await EventBus.app.publishWrappBuild(.progress(.settingUpWrapp(substep: "Installing cnc-ddraw"))) }
        try await installWinetrick("cnc_ddraw", at: wrappPath)
        
        // Configure cnc-ddraw to maintain aspect ratio. windowed=true is what lets
        // native fullscreen adopt the window, but it also makes cnc-ddraw swallow
        // the first click; the wrapp's cursor-lock helper works around that.
        // See docs/wine-in-process-helpers.md before changing these settings.
        let ddrawIniPath = prefixPath.appendingPathComponent("drive_c/windows/syswow64/ddraw.ini")
            if fileManager.fileExists(atPath: ddrawIniPath.path) {
                if let contents = try? String(contentsOf: ddrawIniPath, encoding: .utf8) {
                    var updated = contents.replacingOccurrences(of: "maintas=false", with: "maintas=true")
                    updated = updated.replacingOccurrences(of: "windowed=false", with: "windowed=true")
                    try? updated.write(to: ddrawIniPath, atomically: true, encoding: .utf8)
                    logger.notice("✓ Configured cnc-ddraw to maintain aspect ratio and run in windowed mode")
                }
            }
        
        // Install isolate_home to remove unnecessary mounts
        Task { await EventBus.app.publishWrappBuild(.progress(.settingUpWrapp(substep: "Configuring drive mounts"))) }
        try await installWinetrick("isolate_home", at: wrappPath)
        
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
        try await waitForWineToExit(at: wrappPath)
        
        // Cache the prefix for future use
        try cachePrefix(from: prefixPath, buildId: buildId)
    }    
    /// Mount a directory as a drive in Wine
    func mountDirectory(
        _ sourcePath: String,
        asDrive driveLetter: String,
        type driveType: String = "hd",
        in wrappPath: URL
    ) async throws {
        let prefixPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix")
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
            logger.notice("Setting drive \(driveLetter): type to \(driveType) in Wine registry")
            try await runWine(
                at: wrappPath,
                executable: "wine",
                arguments: [
                    "reg", "add",
                    "HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives",
                    "/v", "\(driveLetter):",
                    "/t", "REG_SZ",
                    "/d", driveType,
                    "/f"
                ],
                // A registry write takes seconds on an idle machine, but over
                // a minute with every core busy (starting the Wine session is
                // most of it); one that runs for ten means the prefix is broken.
                timeout: 600
            )
        }
    }
    
    // MARK: - Wine Execution
    
    /// Run a program with Wine. See `WineEnvironment.runWine` for what it
    /// logs and throws.
    func runWine(
        at wrappPath: URL,
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) async throws {
        let wine = WineEnvironment(appPath: wrappPath)
        try await wine.runWine(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Run a Windows executable through Wine.
    ///
    /// Returns the Wine process exit code rather than throwing for a
    /// non-zero one, which `WineEnvironment.runWine` has already logged as
    /// an error. A signal, a timeout or a failure to start still throws.
    /// Callers that need to treat a non-zero exit as an error should inspect
    /// the returned code.
    @discardableResult
    func runWindowsExecutable(
        at wrappPath: URL,
        exePath: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) async throws -> Int32 {
        let args = [exePath] + arguments
        return try await runWineReturningExitCode(
            at: wrappPath,
            executable: "wine",
            arguments: args,
            timeout: timeout
        )
    }

    /// Run executable with wine start /wait. Returns the exit code like
    /// `runWindowsExecutable`.
    @discardableResult
    func runWindowsExecutableWithStart(
        at wrappPath: URL,
        exePath: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) async throws -> Int32 {
        let wine = WineEnvironment(appPath: wrappPath)
        do {
            try await wine.runWindowsExecutableWithStartAsync(exePath: exePath, arguments: arguments, timeout: timeout)
            return 0
        } catch let WineError.executionFailed(exitCode) {
            return exitCode
        }
    }

    /// Run a Wine program and return its exit code. Shared helper for
    /// `runWindowsExecutable` and friends.
    private func runWineReturningExitCode(
        at wrappPath: URL,
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) async throws -> Int32 {
        do {
            try await runWine(at: wrappPath, executable: executable, arguments: arguments, timeout: timeout)
            return 0
        } catch let WineError.executionFailed(exitCode) {
            return exitCode
        }
    }
    
    /// Wait for Wine server to exit
    func waitForWineToExit(at wrappPath: URL) async throws {
        try await runWine(at: wrappPath, executable: "wineserver", arguments: ["-w"])
    }
    
    /// Start Wine server manually (prevents automatic shutdown)
    func startWineServer(at wrappPath: URL) throws {
        let wine = WineEnvironment(appPath: wrappPath)
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
    func installWinetrick(_ name: String, at wrappPath: URL) async throws {
        // Check if winetricks is bundled
        guard let winetricksPath = Bundle.main.path(forResource: "winetricks", ofType: nil) else {
            throw WineError.winetricksNotFound
        }
        
        let wine = WineEnvironment(appPath: wrappPath)
        
        // Run in detached task to avoid blocking
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached {
                // Streams line-by-line through the logger — live progress during
                // a slow operation, no single multi-MB entry at the end.
                let process = TaggedProcess(logger: self.logger)
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [winetricksPath, "--unattended", name]
                process.environment = wine.environmentVariables()
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: WineError.executionFailed(exitCode: process.terminationStatus))
                        return
                    }
                    
                    self.logger.notice("✓ Successfully installed \(name)")
                    continuation.resume()
                } catch {
                    self.logger.notice("Failed to install winetrick \(name): \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

