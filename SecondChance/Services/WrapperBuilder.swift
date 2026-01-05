//
//  WrapperBuilder.swift
//  SecondChance
//
//  Builds Wine wrapper apps for Nancy Drew games

import Foundation
import AppKit

/// Builds complete Wine wrapper applications for Nancy Drew games
class WrapperBuilder {
    static let shared = WrapperBuilder()
    
    private let fileManager = FileManager.default
    private let wineManager = WineManager.shared
    private let cacheManager = CacheManager.shared
    
    private init() {}
    
    // MARK: - Wrapper Creation
    
    /// Create a base wrapper app with both Wine and ScummVM support
    func createBaseWrapper(at path: URL, progressHandler: ((String) -> Void)? = nil) async throws {
        // Check cache first
        if let _ = try cacheManager.restoreCache(stage: .base, to: path) {
            return
        }
        
        print("Creating unified wrapper with both Wine and ScummVM support...")
        progressHandler?("Copying GameWrapper template")
        
        // Find the pre-built unified template
        guard let templatePath = Bundle.main.url(forResource: "GameWrapper", withExtension: "app") else {
            throw WrapperError.templateNotFound("GameWrapper.app not found in SecondChance.app bundle")
        }
        
        // Copy the entire template (includes both Wine and ScummVM)
        try fileManager.copyItem(at: templatePath, to: path)
        
        progressHandler?("Initializing Wine prefix")
        // Create Wine prefix (ScummVM doesn't need initialization)
        try await wineManager.createWinePrefix(at: path)
        
        // Save to cache
        try cacheManager.saveCache(wrapperPath: path, stage: .base)
    }
    
    /// Remove unused game engine from wrapper after game is determined
    func cleanupUnusedEngine(at wrapperPath: URL, gameEngine: GameInfo.GameEngine) throws {
        print("Cleaning up unused game engine from wrapper...")
        
        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            // Using Wine, remove ScummVM
            let scummvmPath = wrapperPath.appendingPathComponent("Contents/Resources/scummvm")
            if fileManager.fileExists(atPath: scummvmPath.path) {
                print("Removing unused ScummVM files...")
                try fileManager.removeItem(at: scummvmPath)
            }
            
        case .scummvm:
            // Using ScummVM, remove Wine
            let winePath = wrapperPath.appendingPathComponent("Contents/SharedSupport/wine")
            if fileManager.fileExists(atPath: winePath.path) {
                print("Removing unused Wine files...")
                try fileManager.removeItem(at: winePath)
            }
            
            let frameworksPath = wrapperPath.appendingPathComponent("Contents/Frameworks")
            if fileManager.fileExists(atPath: frameworksPath.path) {
                print("Removing unused Wine frameworks...")
                try fileManager.removeItem(at: frameworksPath)
            }
            
            let driveC = wrapperPath.appendingPathComponent("Contents/Resources/drive_c")
            if fileManager.fileExists(atPath: driveC.path) {
                print("Removing unused Wine prefix...")
                try fileManager.removeItem(at: driveC)
            }
        }
        
        print("Cleanup complete")
    }
    
    /// Setup Wine framework in wrapper
    private func setupWineFramework(at wrapperPath: URL) async throws {
        let wineDestPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/wine")
        let frameworksDestPath = wrapperPath.appendingPathComponent("Contents/Frameworks")
        
        // Check if already set up
        if fileManager.fileExists(atPath: wineDestPath.appendingPathComponent("bin/wine").path) &&
           fileManager.fileExists(atPath: frameworksDestPath.path) {
            print("Wine framework already exists")
            return
        }
        
        print("Setting up Wine framework...")
        
        // Try to find local cached files first (only accessible if app has permission to the source directory)
        let localWineEnginePath = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance/game-wrapper/build/wine-engine")
        let localWineskinPath = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance/game-wrapper/build/wineskin")
        
        // Check if files exist AND if we can actually read them (important for sandboxed apps)
        let canAccessLocalFiles = fileManager.fileExists(atPath: localWineEnginePath.path) &&
                                   fileManager.fileExists(atPath: localWineskinPath.path) &&
                                   fileManager.isReadableFile(atPath: localWineEnginePath.path) &&
                                   fileManager.isReadableFile(atPath: localWineskinPath.path)
        
        if canAccessLocalFiles {
            print("Using local Wine files from game-wrapper/build/")
            
            // Ensure destination directories exist
            try fileManager.createDirectory(at: wineDestPath.deletingLastPathComponent(), 
                                           withIntermediateDirectories: true)
            
            // Copy Wine engine
            print("Copying wine-engine from \(localWineEnginePath.path)")
            print("            to \(wineDestPath.path)")
            
            do {
                try fileManager.copyItem(at: localWineEnginePath, to: wineDestPath)
                
                // Restore executable permissions on wine binaries
                print("Setting executable permissions on wine binaries...")
                let binPath = wineDestPath.appendingPathComponent("bin")
                let binContents = try fileManager.contentsOfDirectory(at: binPath, includingPropertiesForKeys: nil)
                for binaryURL in binContents {
                    // Set executable permissions (0755 = rwxr-xr-x)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: binaryURL.path
                    )
                }
                
                // Fix rpaths in Wine binaries to point to Frameworks directory
                print("Fixing rpaths in wine binaries...")
                try fixWineRpaths(wineDestPath: wineDestPath, frameworksPath: frameworksDestPath)
                
                // Verify the copy succeeded
                let wineBinaryPath = wineDestPath.appendingPathComponent("bin/wine")
                if fileManager.fileExists(atPath: wineBinaryPath.path) {
                    let attrs = try fileManager.attributesOfItem(atPath: wineBinaryPath.path)
                    let perms = attrs[.posixPermissions] as? NSNumber
                    print("Wine binary verified at: \(wineBinaryPath.path)")
                    print("Wine binary permissions: \(String(format: "%o", perms?.uint16Value ?? 0))")
                    
                    // Note: isExecutableFile may return false in sandbox even with correct permissions
                    // This is a sandbox API limitation, not an actual permission issue
                    if fileManager.isExecutableFile(atPath: wineBinaryPath.path) {
                        print("Wine binary is executable (according to FileManager)")
                    } else {
                        print("Note: FileManager.isExecutableFile returns false, but this is expected in sandbox")
                        print("The binary has correct permissions (755) and should work when executed")
                    }
                } else {
                    print("ERROR: Wine binary not found after copy at: \(wineBinaryPath.path)")
                    throw WrapperError.wineNotFound
                }
            } catch {
                print("Failed to copy wine-engine: \(error.localizedDescription)")
                print("Note: The app may not have permission to read from the source directory.")
                print("Consider downloading instead or granting permission.")
                throw error
            }
            
            // Copy Frameworks from Wineskin
            let wineskinFrameworksPath = localWineskinPath.appendingPathComponent("Contents/Frameworks")
            print("Copying frameworks from \(wineskinFrameworksPath.path)")
            print("               to \(frameworksDestPath.path)")
            
            do {
                // Remove existing Frameworks directory if it exists
                if fileManager.fileExists(atPath: frameworksDestPath.path) {
                    try fileManager.removeItem(at: frameworksDestPath)
                }
                try fileManager.copyItem(at: wineskinFrameworksPath, to: frameworksDestPath)
            } catch {
                print("Failed to copy frameworks: \(error.localizedDescription)")
                throw error
            }
            
            print("Wine framework installed successfully from local cache")
            return
        }
        
        print("Local Wine files not accessible or not found")
        
        // If local files don't exist, try downloading
        print("Local Wine files not found, attempting to download...")
        
        // Download Wine engine
        let wineEngineURL = URL(string: "https://github.com/Kegworks-App/Engines/releases/download/v1.0/WS12WineCX24.0.7.tar.xz")!
        let wineEngineCache = try await downloadAndCacheFile(url: wineEngineURL, name: "wine-engine.tar.xz")
        
        print("Wine engine downloaded/cached at: \(wineEngineCache.path)")
        
        // Extract Wine engine
        let wineEngineExtracted = wineEngineCache.deletingLastPathComponent().appendingPathComponent("wine-engine")
        print("Will extract to: \(wineEngineExtracted.path)")
        
        // Check if extraction exists AND is valid (has wine binary)
        let extractedWineBinary = wineEngineExtracted.appendingPathComponent("bin/wine")
        let needsExtraction = !fileManager.fileExists(atPath: extractedWineBinary.path)
        
        if needsExtraction {
            if fileManager.fileExists(atPath: wineEngineExtracted.path) {
                print("Extracted directory exists but is invalid, removing and re-extracting...")
                try fileManager.removeItem(at: wineEngineExtracted)
            } else {
                print("Extracted directory doesn't exist, extracting now...")
            }
            try await extractTarArchive(from: wineEngineCache, to: wineEngineExtracted)
            print("Extraction complete")
        } else {
            print("Using previously extracted wine-engine")
        }
        
        // Verify extracted wine exists
        guard fileManager.fileExists(atPath: extractedWineBinary.path) else {
            print("ERROR: Extracted wine binary not found at: \(extractedWineBinary.path)")
            throw WrapperError.wineNotFound
        }
        print("Verified extracted wine binary at: \(extractedWineBinary.path)")
        
        // Copy Wine to wrapper
        print("Copying extracted wine to wrapper at: \(wineDestPath.path)")
        
        // Ensure parent directory exists
        try fileManager.createDirectory(at: wineDestPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        try fileManager.copyItem(at: wineEngineExtracted, to: wineDestPath)
        
        // Verify Wine binary exists in wrapper
        let wrapperWineBinary = wineDestPath.appendingPathComponent("bin/wine")
        guard fileManager.fileExists(atPath: wrapperWineBinary.path) else {
            print("ERROR: Wine binary not found in wrapper at: \(wrapperWineBinary.path)")
            throw WrapperError.wineNotFound
        }
        
        print("Wine engine installed successfully")
        
        // Download Wineskin wrapper for frameworks
        let wineskinURL = URL(string: "https://github.com/Kegworks-App/Wrapper/releases/download/v1.0/Wineskin-3.1.7_2.tar.xz")!
        let wineskinCache = try await downloadAndCacheFile(url: wineskinURL, name: "wineskin-wrapper.tar.xz")
        
        // Extract Wineskin wrapper
        let wineskinExtracted = wineskinCache.deletingLastPathComponent().appendingPathComponent("wineskin")
        if !fileManager.fileExists(atPath: wineskinExtracted.path) {
            try await extractTarArchive(from: wineskinCache, to: wineskinExtracted)
        }
        
        // Copy Frameworks from Wineskin
        let wineskinFrameworksPath = wineskinExtracted.appendingPathComponent("Contents/Frameworks")
        
        // Remove existing Frameworks directory if it exists
        if fileManager.fileExists(atPath: frameworksDestPath.path) {
            print("Removing existing Frameworks directory...")
            try fileManager.removeItem(at: frameworksDestPath)
        }
        
        print("Copying Frameworks from Wineskin...")
        try fileManager.copyItem(at: wineskinFrameworksPath, to: frameworksDestPath)
        
        print("Wineskin frameworks installed successfully")
    }
    
    /// Fix rpaths in Wine binaries to point to the Frameworks directory
    private func fixWineRpaths(wineDestPath: URL, frameworksPath: URL) throws {
        let binPath = wineDestPath.appendingPathComponent("bin")
        let libPath = wineDestPath.appendingPathComponent("lib")
        
        // Calculate the relative path from bin to Frameworks
        // bin is at: Contents/SharedSupport/wine/bin
        // Frameworks is at: Contents/Frameworks
        // Relative path: ../../../Frameworks
        let rpathToFrameworks = "@executable_path/../../../Frameworks"
        
        print("Fixing rpaths in Wine binaries to: \(rpathToFrameworks)")
        
        // Get all binaries in bin directory
        guard let binContents = try? fileManager.contentsOfDirectory(at: binPath, includingPropertiesForKeys: nil) else {
            print("Warning: Could not read wine bin directory")
            return
        }
        
        var fixedCount = 0
        var failedCount = 0
        
        for binaryURL in binContents {
            // Skip non-executable files
            guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
                continue
            }
            
            // Use install_name_tool to add rpath
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/install_name_tool")
            process.arguments = [
                "-add_rpath",
                rpathToFrameworks,
                binaryURL.path
            ]
            
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe() // Suppress output
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 {
                    fixedCount += 1
                } else {
                    // Check if error is "would duplicate path" which is fine
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorStr = String(data: errorData, encoding: .utf8) ?? ""
                    if errorStr.contains("would duplicate path") {
                        // Already has this rpath, that's ok
                        fixedCount += 1
                    } else {
                        print("Warning: Failed to fix rpath for \(binaryURL.lastPathComponent): \(errorStr)")
                        failedCount += 1
                    }
                }
            } catch {
                print("Warning: Could not run install_name_tool on \(binaryURL.lastPathComponent): \(error)")
                failedCount += 1
            }
        }
        
        print("Fixed rpaths in \(fixedCount) Wine binaries (\(failedCount) failed)")
    }
    
    /// Setup runtime scripts in wrapper
    private func setupRuntimeScripts(at wrapperPath: URL, progressHandler: ((String) -> Void)? = nil) throws {
        print("Setting up runtime scripts...")
        
        // Path to the source files
        let projectRoot = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance")
        let sharedScriptsPath = projectRoot.appendingPathComponent("shared")
        let gameWrapperPath = projectRoot.appendingPathComponent("game-wrapper")
        let swiftRuntimePath = projectRoot.appendingPathComponent("SecondChance/Resources/GameWrapperRuntime/main.swift")
        
        // Destination paths in the wrapper
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        let macOSPath = wrapperPath.appendingPathComponent("Contents/MacOS")
        
        // Create directories
        try fileManager.createDirectory(at: resourcesPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: macOSPath, withIntermediateDirectories: true)
        
        // Copy Swift runtime source if it exists
        if fileManager.fileExists(atPath: swiftRuntimePath.path) {
            let runtimeDestDir = resourcesPath.appendingPathComponent("GameWrapperRuntime")
            try fileManager.createDirectory(at: runtimeDestDir, withIntermediateDirectories: true)
            
            let runtimeDestPath = runtimeDestDir.appendingPathComponent("main.swift")
            if fileManager.fileExists(atPath: runtimeDestPath.path) {
                try fileManager.removeItem(at: runtimeDestPath)
            }
            
            try fileManager.copyItem(at: swiftRuntimePath, to: runtimeDestPath)
            print("Copied Swift runtime source to wrapper")
            
            // Also copy WineEnvironment.swift from Services
            let wineEnvSourcePath = projectRoot.appendingPathComponent("SecondChance/SecondChance/Services/WineEnvironment.swift")
            if fileManager.fileExists(atPath: wineEnvSourcePath.path) {
                let wineEnvDestPath = runtimeDestDir.appendingPathComponent("WineEnvironment.swift")
                if fileManager.fileExists(atPath: wineEnvDestPath.path) {
                    try fileManager.removeItem(at: wineEnvDestPath)
                }
                try fileManager.copyItem(at: wineEnvSourcePath, to: wineEnvDestPath)
                print("Copied WineEnvironment.swift to wrapper")
            }
        }
        
        // Copy scummvm.ini if exists (still needed for ScummVM engine)
        let scummvmSource = gameWrapperPath.appendingPathComponent("scummvm.ini")
        if fileManager.fileExists(atPath: scummvmSource.path) {
            let scummvmDest = resourcesPath.appendingPathComponent("scummvm.ini")
            if fileManager.fileExists(atPath: scummvmDest.path) {
                try fileManager.removeItem(at: scummvmDest)
            }
            try fileManager.copyItem(at: scummvmSource, to: scummvmDest)
            print("Copied scummvm.ini to wrapper")
        }
        
        // Create launcher executable in MacOS
        progressHandler?("Compiling Swift runtime")
        try createLauncherExecutable(at: macOSPath, wrapperPath: wrapperPath, progressHandler: progressHandler)
        
        print("Runtime scripts setup complete")
    }
    
    /// Create the main launcher executable
    private func createLauncherExecutable(at macOSPath: URL, wrapperPath: URL, progressHandler: ((String) -> Void)? = nil) throws {
        let launcherPath = macOSPath.appendingPathComponent("GameWrapper")
        
        // Get path to Swift runtime source in the wrapper's Resources
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        let runtimeSourcePath = resourcesPath.appendingPathComponent("GameWrapperRuntime/main.swift")
        let sharedSourcePath = resourcesPath.appendingPathComponent("GameWrapperRuntime/WineEnvironment.swift")
        
        // If we have the Swift runtime source, compile it
        if fileManager.fileExists(atPath: runtimeSourcePath.path) {
            print("Compiling Swift runtime...")
            progressHandler?("Compiling Swift runtime")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            
            // Compile both source files together
            var sourceFiles = [runtimeSourcePath.path]
            if fileManager.fileExists(atPath: sharedSourcePath.path) {
                sourceFiles.append(sharedSourcePath.path)
            }
            
            process.arguments = sourceFiles + [
                "-o", launcherPath.path,
                "-O" // Optimize
            ]
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                print("❌ Swift compilation failed: \(errorMessage)")
                throw WrapperError.swiftCompilationFailed(errorMessage)
            } else {
                print("✅ Created Swift launcher executable: GameWrapper")
                
                // Code sign the entire wrapper app bundle
                // This is necessary because the wrapper contains frameworks and other code
                print("Signing wrapper app bundle...")
                progressHandler?("Signing wrapper app bundle")
                let signProcess = Process()
                signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                signProcess.arguments = [
                    "-s", "-",  // Ad-hoc signing
                    "--force",
                    "--deep",  // Sign all nested code including frameworks
                    wrapperPath.path
                ]
                
                let signOutputPipe = Pipe()
                let signErrorPipe = Pipe()
                signProcess.standardOutput = signOutputPipe
                signProcess.standardError = signErrorPipe
                
                try signProcess.run()
                signProcess.waitUntilExit()
                
                if signProcess.terminationStatus == 0 {
                    print("✅ Signed wrapper app bundle")
                } else {
                    let errorData = signErrorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    print("⚠️ Warning: Failed to sign wrapper: \(errorMessage)")
                    print("The wrapper may not run on some systems")
                }
            }
        } else {
            print("❌ Swift runtime source not found at \(runtimeSourcePath.path)")
            throw WrapperError.swiftRuntimeNotFound
        }
    }
    
    /// Create bash launcher as fallback
    private func createBashLauncher(at launcherPath: URL) throws {
        let launcherScript = """
            #!/bin/bash
            # Launcher for Nancy Drew Game Wrapper
            
            # Get the directory of this script
            SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
            APP_DIR="$( cd "$SCRIPT_DIR/../.." && pwd )"
            RESOURCES_DIR="$APP_DIR/Contents/Resources"
            
            # Execute the main entrypoint script
            exec "$RESOURCES_DIR/script"
            """
        
        // Write the launcher script
        try launcherScript.write(to: launcherPath, atomically: true, encoding: .utf8)
        
        // Make it executable
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherPath.path
        )
        
        print("Created bash launcher executable: GameWrapper")
    }
    
    /// Download and cache a file using URLSession with progress reporting
    private func downloadAndCacheFile(url: URL, name: String) async throws -> URL {
        let cacheDir = fileManager.temporaryDirectory.appendingPathComponent("SecondChance/Downloads")
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let cachePath = cacheDir.appendingPathComponent(name)
        
        // Return cached file if it exists
        if fileManager.fileExists(atPath: cachePath.path) {
            print("Using cached file: \(name)")
            return cachePath
        }
        
        print("Downloading \(name) from \(url.absoluteString)...")
        
        // Create a URLSession with a delegate to track progress
        let delegate = DownloadDelegate(fileName: name)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        
        let (downloadedFileURL, response) = try await session.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WrapperError.downloadFailed
        }
        
        try fileManager.moveItem(at: downloadedFileURL, to: cachePath)
        
        print("Downloaded \(name) successfully")
        return cachePath
    }
    
    /// URLSessionDownloadDelegate to track download progress
    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let fileName: String
        var lastPrintedProgress: Int = -1
        
        init(fileName: String) {
            self.fileName = fileName
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            
            let progress = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100)
            
            // Only print every 10% to avoid flooding the console
            if progress != lastPrintedProgress && progress % 10 == 0 {
                lastPrintedProgress = progress
                let mbWritten = Double(totalBytesWritten) / 1_048_576.0
                let mbTotal = Double(totalBytesExpectedToWrite) / 1_048_576.0
                print(String(format: "Downloading %@: %.1f / %.1f MB (%d%%)", fileName, mbWritten, mbTotal, progress))
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // Required delegate method - actual handling is done in the async function
        }
    }
    
    /// Extract tar archive
    private func extractTarArchive(from source: URL, to destination: URL) async throws {
        // Create temp directory as a sibling, not a child of destination
        let tempDestination = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".tmp")
        
        // Clean up any existing temp or final directories
        if fileManager.fileExists(atPath: tempDestination.path) {
            try fileManager.removeItem(at: tempDestination)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        
        try fileManager.createDirectory(at: tempDestination, withIntermediateDirectories: true)
        
        print("Extracting \(source.lastPathComponent)... (this may take a minute)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xf", source.path, "-C", tempDestination.path, "--strip-components=1"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Print dots periodically to show progress
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            print(".", terminator: "")
            fflush(stdout)
        }
        
        try process.run()
        process.waitUntilExit()
        
        progressTimer.invalidate()
        print("") // New line after dots
        
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("Extraction error: \(errorMessage)")
            throw WrapperError.extractionFailed(errorMessage)
        }
        
        print("Extraction completed, moving to final location...")
        
        // Move to final destination
        try fileManager.moveItem(at: tempDestination, to: destination)
        
        print("Extracted to \(destination.path)")
    }
    
    /// Create Info.plist for wrapper
    private func createInfoPlist(at wrapperPath: URL) throws {
        let infoPlistPath = wrapperPath.appendingPathComponent("Contents/Info.plist")
        
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.secondchance.nancydrew",
            "CFBundleName": "Nancy Drew",
            "CFBundleDisplayName": "Nancy Drew",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": "GameWrapper",
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "LSMinimumSystemVersion": "10.13",
            "NSHighResolutionCapable": true,
            "NSMicrophoneUsageDescription": "Steam requires access to the microphone"
        ]
        
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoPlistPath)
    }
    
    // MARK: - Game Installation
    
    /// Copy game installer disks into wrapper
    func copyGameDisks(
        disk1: URL,
        disk2: URL?,
        to wrapperPath: URL,
        gameSlug: String
    ) async throws {
        // Check cache first
        if let metadata = try cacheManager.restoreCache(stage: .diskGameInstallerCopied, to: wrapperPath) {
            if metadata.gameSlug == gameSlug {
                return
            } else {
                throw WrapperError.cachedGameMismatch
            }
        }
        
        print("Copying game disks...")
        
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let installerPath = driveCPath.appendingPathComponent("nancy-drew-installer")
        
        try fileManager.createDirectory(at: installerPath, withIntermediateDirectories: true)
        
        // Copy disk 1 on background queue
        let disk1Dest = installerPath.appendingPathComponent("disk-1")
        try await Task.detached {
            try FileManager.default.copyItem(at: disk1, to: disk1Dest)
        }.value
        
        // Copy disk 2 if present
        if let disk2 = disk2 {
            let disk2Dest = installerPath.appendingPathComponent("disk-2")
            try await Task.detached {
                try FileManager.default.copyItem(at: disk2, to: disk2Dest)
            }.value
            
            // Create combined disk directory with symlinks
            let combinedDest = installerPath.appendingPathComponent("disk-combined")
            try fileManager.createDirectory(at: combinedDest, withIntermediateDirectories: true)
            
            // Symlink disk 1 contents
            let disk1Contents = try fileManager.contentsOfDirectory(at: disk1Dest, includingPropertiesForKeys: nil)
            for item in disk1Contents {
                let linkPath = combinedDest.appendingPathComponent(item.lastPathComponent)
                try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: item)
            }
            
            // Symlink disk 2 contents
            let disk2Contents = try fileManager.contentsOfDirectory(at: disk2Dest, includingPropertiesForKeys: nil)
            for item in disk2Contents {
                let linkPath = combinedDest.appendingPathComponent(item.lastPathComponent)
                if !fileManager.fileExists(atPath: linkPath.path) {
                    try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: item)
                }
            }
        }
        
        // Copy setup.iss file if it exists for this game
        if let issPath = Bundle.main.path(forResource: gameSlug, ofType: "iss", inDirectory: "installer-answer-files") {
            let setupIssDestPath = installerPath.appendingPathComponent("setup.iss")
            do {
                try fileManager.copyItem(atPath: issPath, toPath: setupIssDestPath.path)
                print("✅ Copied setup.iss for \(gameSlug)")
            } catch {
                print("⚠️ Failed to copy setup.iss: \(error)")
            }
        } else {
            print("ℹ️ No setup.iss file found for \(gameSlug)")
        }
        
        // Save to cache
        try cacheManager.saveCache(wrapperPath: wrapperPath, stage: .diskGameInstallerCopied, gameSlug: gameSlug)
    }
    
    /// Install Steam client in wrapper
    func installSteamClient(in wrapperPath: URL) async throws {
        // Check cache first
        if let _ = try cacheManager.restoreCache(stage: .steamClientInstalled, to: wrapperPath) {
            return
        }
        
        print("Installing Steam client...")
        
        // Stop wine server first
        try wineManager.stopWineServer(at: wrapperPath)
        
        // Install Steam via winetricks
        try await wineManager.installWinetrick("steam", at: wrapperPath)
        
        // Save to cache
        try cacheManager.saveCache(wrapperPath: wrapperPath, stage: .steamClientInstalled)
    }
    
    /// Configure wrapper for game
    func configureWrapper(
        at wrapperPath: URL,
        gameInfo: GameInfo,
        gameExePath: String,
        installerDir: String,
        steamID: String? = nil
    ) throws {
        print("Configuring wrapper for \(gameInfo.title)...")
        
        let infoPlistPath = wrapperPath.appendingPathComponent("Contents/Info.plist")
        
        // Update Info.plist
        guard let plistData = try? Data(contentsOf: infoPlistPath),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw WrapperError.invalidInfoPlist
        }
        
        // Update bundle identifier
        let bundleID = "com.secondchance.nancydrew.\(gameInfo.id)"
        plist["CFBundleIdentifier"] = bundleID + ".\(Int.random(in: 0..<100000))"
        plist["CFBundleIdentifierForGameTitle"] = bundleID
        plist["CFBundleName"] = "Nancy Drew - \(gameInfo.title)"
        plist["CFBundleDisplayName"] = "Nancy Drew - \(gameInfo.title)"
        plist["Program Name and Path"] = gameExePath
        
        // Save updated plist
        let updatedData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updatedData.write(to: infoPlistPath)
        
        // Create AppSettings.plist for runtime script
        try createAppSettingsPlist(
            at: wrapperPath,
            gameInfo: gameInfo,
            gameExePath: gameExePath,
            installerDir: installerDir,
            steamID: steamID
        )
        
        // Configure game INI files for LCD mode and save path
        try configureGameINI(at: wrapperPath, gameExePath: gameExePath)
    }
    
    /// Create AppSettings.plist for the runtime script to read
    private func createAppSettingsPlist(
        at wrapperPath: URL,
        gameInfo: GameInfo,
        gameExePath: String,
        installerDir: String,
        steamID: String?
    ) throws {
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        let appSettingsPath = resourcesPath.appendingPathComponent("AppSettings.plist")
        
        // Ensure Resources directory exists
        if !fileManager.fileExists(atPath: resourcesPath.path) {
            try fileManager.createDirectory(at: resourcesPath, withIntermediateDirectories: true)
        }
        
        // Convert GameEngine enum to string for config
        let gameEngine: String
        switch gameInfo.gameEngine {
        case .wine:
            gameEngine = "wine"
        case .scummvm:
            gameEngine = "scummvm"
        case .wineSteam:
            gameEngine = "wine-steam"
        case .wineSteamSilent:
            gameEngine = "wine-steam-silent"
        }
        
        // Create settings dictionary
        var settings: [String: Any] = [
            "GameExePath": gameExePath,
            "GameEngine": gameEngine,
            "GameInstallerDir": installerDir
        ]
        
        // Add Steam ID if present
        if let steamID = steamID {
            settings["SteamGameId"] = steamID
        }
        
        // Write plist
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        try data.write(to: appSettingsPath)
        
        print("Created AppSettings.plist with engine: \(gameEngine)")
    }
    
    /// Configure game INI files
    private func configureGameINI(at wrapperPath: URL, gameExePath: String) throws {
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let gameDir = URL(fileURLWithPath: gameExePath, relativeTo: driveCPath).deletingLastPathComponent()
        
        // Find INI files in game directory
        let contents = try? fileManager.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: nil,
            options: []
        )
        
        guard let iniFiles = contents?.filter({ $0.pathExtension.lowercased() == "ini" }) else {
            return
        }
        
        for iniFile in iniFiles {
            guard var content = try? String(contentsOf: iniFile, encoding: .utf8) else {
                continue
            }
            
            // Set LCD mode (WindowMode=2)
            content = content.replacingOccurrences(of: "WindowMode=0", with: "WindowMode=2")
            
            // Set save path to Documents
            let savePath = "LoadSavePath=\\\\users\\\\crossover\\\\Documents"
            content = content.replacingOccurrences(
                of: #"LoadSavePath=.*"#,
                with: savePath,
                options: .regularExpression
            )
            
            try content.write(to: iniFile, atomically: true, encoding: .utf8)
        }
    }
    
    /// Sign the wrapper app
    func signWrapper(at path: URL) throws {
        print("Signing wrapper...")
        
        // Remove existing signature
        let codesignRemove = Process()
        codesignRemove.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesignRemove.arguments = ["--remove-signature", path.path]
        try codesignRemove.run()
        codesignRemove.waitUntilExit()
        
        // Sign frameworks
        let frameworksPath = path.appendingPathComponent("Contents/Frameworks")
        if fileManager.fileExists(atPath: frameworksPath.path) {
            let enumerator = fileManager.enumerator(at: frameworksPath, includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                if file.pathExtension.isEmpty && !file.hasDirectoryPath {
                    let sign = Process()
                    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                    sign.arguments = ["-s", "-", file.path]
                    try? sign.run()
                    sign.waitUntilExit()
                }
            }
        }
        
        // Remove .DS_Store files
        let dsStoreEnumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: nil)
        while let file = dsStoreEnumerator?.nextObject() as? URL {
            if file.lastPathComponent == ".DS_Store" {
                try? fileManager.removeItem(at: file)
            }
        }
        
        // Sign app bundle
        let codesignApp = Process()
        codesignApp.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesignApp.arguments = ["-s", "-", path.path]
        try codesignApp.run()
        codesignApp.waitUntilExit()
    }
}

// MARK: - Errors

enum WrapperError: LocalizedError {
    case cachedGameMismatch
    case invalidInfoPlist
    case wineNotFound
    case downloadFailed
    case downloadFailedWithReason(String)
    case extractionFailed(String)
    case runtimeCompilationFailed
    case swiftCompilationFailed(String)
    case swiftRuntimeNotFound
    case templateNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .cachedGameMismatch:
            return "Cached wrapper game does not match detected game"
        case .invalidInfoPlist:
            return "Could not read or parse Info.plist"
        case .wineNotFound:
            return "Wine framework not found"
        case .downloadFailed:
            return "Failed to download required files"
        case .downloadFailedWithReason(let reason):
            return "Failed to download required files: \(reason)"
        case .extractionFailed(let message):
            return "Failed to extract archive: \(message)"
        case .runtimeCompilationFailed:
            return "Failed to compile Swift runtime"
        case .swiftCompilationFailed(let message):
            return "Swift compilation failed: \(message)"
        case .swiftRuntimeNotFound:
            return "Swift runtime source files not found"
        case .templateNotFound(let message):
            return "Game wrapper template not found: \(message)"
        }
    }
}
