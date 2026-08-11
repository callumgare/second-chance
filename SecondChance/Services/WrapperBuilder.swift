//
//  WrapperBuilder.swift
//  SecondChance
//
//  Builds Wine wrapper apps for Nancy Drew games

import Foundation
import os
import AppKit

/// Builds complete Wine wrapper applications for Nancy Drew games
class WrapperBuilder {
    static let shared = WrapperBuilder()
    
    private let fileManager = FileManager.default
    private let wineManager = WineManager.shared
    private let cacheManager = CacheManager.shared
    private let logger = Logger(subsystem: "com.secondchance", category: "WrapperBuilder")
    
    private init() {}
    
    // MARK: - Helper Methods
    
    /// Copy directory using shell command with symlink dereferencing
    /// This works around VirtualBuddy shared folder symlink issues
    private func copyItemDerefencingSymlinks(at source: URL, to destination: URL) throws {
        let executable = "/bin/cp"
        // -R: recursive, -P: preserve symlinks (don't dereference)
        let arguments = ["-a", source.path, destination.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe() // Suppress output
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            let command = formatShellCommand(executable: executable, arguments: arguments)
            throw WrapperError.copyFailed(message: "cp command failed", command: command, output: errorMessage)
        }
    }
    
    // MARK: - Wrapper Creation
    
    /// Create a base wrapper app with both Wine and ScummVM support
    func createBaseWrapper(at path: URL) async throws {
        // Check cache first
        if let _ = try cacheManager.restoreCache(stage: .base, to: path) {
            return
        }
        
        logger.notice("Creating unified wrapper with both Wine and ScummVM support...")
        Task { await EventBus.app.publishInstallation(.progress(.settingUpWrapper(substep: nil))) }
        
        // Find the pre-built unified template
        guard let templatePath = Bundle.main.url(forResource: "GameWrapper", withExtension: "app") else {
            throw WrapperError.templateNotFound("GameWrapper.app not found in Second Chance.app bundle")
        }
        
        // Copy the entire template (includes both Wine and ScummVM)
        do {
            // Use cp -RP to work around VirtualBuddy shared folder symlink issues
            try copyItemDerefencingSymlinks(at: templatePath, to: path)
        } catch {
            if let wrapperError = error as? WrapperError, let output = wrapperError.copyOutput {
                logger.notice("Copy output: \(output, privacy: .public)")
            }
            logger.fault("❌ Failed to copy GameWrapper template: \(error.localizedDescription, privacy: .public)")
            if let wrapperError = error as? WrapperError, let command = wrapperError.copyCommand {
                logger.notice("   Command: \(command, privacy: .public)")
            }
            logger.notice("📋 Template copy details:")
            logger.notice("   Source: \(templatePath.path, privacy: .public)")
            logger.notice("   Dest:   \(path.path, privacy: .public)")
            
            // Check the Frameworks in the template
            let templateFrameworks = templatePath.appendingPathComponent("Contents/Frameworks")
            if let contents = try? fileManager.contentsOfDirectory(atPath: templateFrameworks.path) {
                logger.notice("   Template Frameworks contains \(contents.count, privacy: .public) items")
                let p11Files = contents.filter { $0.contains("p11") }
                if !p11Files.isEmpty {
                    logger.notice("   p11-related files in template: \(p11Files.joined(separator: ", "), privacy: .public)")
                    for p11File in p11Files {
                        let filePath = templateFrameworks.appendingPathComponent(p11File)
                        if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path) {
                            let isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                            logger.notice("     - \(p11File, privacy: .public): \(isSymlink ? "symlink" : "regular file", privacy: .public)")
                            if isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: filePath.path) {
                                logger.notice("       → \(target, privacy: .public)")
                                // Check if target exists
                                let targetPath = templateFrameworks.appendingPathComponent(target)
                                let targetExists = fileManager.fileExists(atPath: targetPath.path)
                                logger.notice("       Target exists: \(targetExists, privacy: .public)")
                                if targetExists, let targetAttrs = try? fileManager.attributesOfItem(atPath: targetPath.path) {
                                    let targetIsSymlink = targetAttrs[.type] as? FileAttributeType == .typeSymbolicLink
                                    if targetIsSymlink, let nextTarget = try? fileManager.destinationOfSymbolicLink(atPath: targetPath.path) {
                                        logger.notice("       Target is also symlink → \(nextTarget, privacy: .public)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            logger.notice("   Full error: \(error, privacy: .public)")
            if let nsError = error as NSError? {
                logger.notice("   Domain: \(nsError.domain, privacy: .public)")
                logger.notice("   Code: \(nsError.code, privacy: .public)")
                logger.notice("   UserInfo: \(nsError.userInfo, privacy: .public)")
            }
            throw error
        }
        
        // Create Wine prefix (ScummVM doesn't need initialization)
        try await wineManager.createWinePrefix(at: path)
        
        // Save to cache
        try cacheManager.saveCache(wrapperPath: path, stage: .base)
    }
    
    /// Remove unused game engine from wrapper after game is determined
    func cleanupUnusedEngine(at wrapperPath: URL, gameEngine: GameInfo.GameEngine) throws {
        logger.notice("Cleaning up unused game engine from wrapper...")
        
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        
        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            // Using Wine, remove ScummVM files listed in scummvm-files
            let scummvmFilesPath = resourcesPath.appendingPathComponent("scummvm-files")
            if fileManager.fileExists(atPath: scummvmFilesPath.path) {
                logger.notice("Reading ScummVM files list...")
                if let content = try? String(contentsOf: scummvmFilesPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    logger.notice("Found \(lines.count, privacy: .public) ScummVM files/directories to remove")
                    
                    for relativePath in lines {
                        let pathToRemove = wrapperPath.appendingPathComponent(relativePath)
                        if fileManager.fileExists(atPath: pathToRemove.path) {
                            try fileManager.removeItem(at: pathToRemove)
                        }
                    }
                }
            } else {
                logger.error("Warning: scummvm-files list not found at \(scummvmFilesPath.path, privacy: .public)")
            }
            
        case .scummvm:
            // Using ScummVM, remove Wine files listed in wine-files
            let wineFilesPath = resourcesPath.appendingPathComponent("wine-files")
            if fileManager.fileExists(atPath: wineFilesPath.path) {
                logger.notice("Reading Wine files list...")
                if let content = try? String(contentsOf: wineFilesPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    logger.notice("Found \(lines.count, privacy: .public) Wine files/directories to remove")
                    
                    for relativePath in lines {
                        let pathToRemove = wrapperPath.appendingPathComponent(relativePath)
                        if fileManager.fileExists(atPath: pathToRemove.path) {
                            try fileManager.removeItem(at: pathToRemove)
                        }
                    }
                }
            } else {
                logger.error("Warning: wine-files list not found at \(wineFilesPath.path, privacy: .public)")
            }
        }
        
        logger.notice("Cleanup complete")
    }
    
    /// Setup Wine framework in wrapper
    private func setupWineFramework(at wrapperPath: URL) async throws {
        let wineDestPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/wine")
        let frameworksDestPath = wrapperPath.appendingPathComponent("Contents/Frameworks")
        
        // Check if already set up
        if fileManager.fileExists(atPath: wineDestPath.appendingPathComponent("bin/wine").path) &&
           fileManager.fileExists(atPath: frameworksDestPath.path) {
            logger.notice("Wine framework already exists")
            return
        }
        
        logger.notice("Setting up Wine framework...")
        
        // Try to find local cached files first (only accessible if app has permission to the source directory)
        let localWineEnginePath = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance/game-wrapper/build/wine-engine")
        let localWineskinPath = URL(fileURLWithPath: "/Users/callumgare/repos/second-chance/game-wrapper/build/wineskin")
        
        // Check if files exist AND if we can actually read them (important for sandboxed apps)
        let canAccessLocalFiles = fileManager.fileExists(atPath: localWineEnginePath.path) &&
                                   fileManager.fileExists(atPath: localWineskinPath.path) &&
                                   fileManager.isReadableFile(atPath: localWineEnginePath.path) &&
                                   fileManager.isReadableFile(atPath: localWineskinPath.path)
        
        if canAccessLocalFiles {
            logger.notice("Using local Wine files from game-wrapper/build/")
            
            // Ensure destination directories exist
            try fileManager.createDirectory(at: wineDestPath.deletingLastPathComponent(), 
                                           withIntermediateDirectories: true)
            
            // Copy Wine engine
            logger.notice("Copying wine-engine from \(localWineEnginePath.path, privacy: .public)")
            logger.notice("            to \(wineDestPath.path, privacy: .public)")
            
            do {
                try fileManager.copyItem(at: localWineEnginePath, to: wineDestPath)
                
                // Restore executable permissions on wine binaries
                logger.notice("Setting executable permissions on wine binaries...")
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
                logger.notice("Fixing rpaths in wine binaries...")
                try fixWineRpaths(wineDestPath: wineDestPath, frameworksPath: frameworksDestPath)
                
                // Verify the copy succeeded
                let wineBinaryPath = wineDestPath.appendingPathComponent("bin/wine")
                if fileManager.fileExists(atPath: wineBinaryPath.path) {
                    let attrs = try fileManager.attributesOfItem(atPath: wineBinaryPath.path)
                    let perms = attrs[.posixPermissions] as? NSNumber
                    logger.notice("Wine binary verified at: \(wineBinaryPath.path, privacy: .public)")
                    logger.notice("Wine binary permissions: \(String(format: "%o", perms?.uint16Value ?? 0), privacy: .public)")
                    
                    // Note: isExecutableFile may return false in sandbox even with correct permissions
                    // This is a sandbox API limitation, not an actual permission issue
                    if fileManager.isExecutableFile(atPath: wineBinaryPath.path) {
                        logger.notice("Wine binary is executable (according to FileManager)")
                    } else {
                        logger.notice("Note: FileManager.isExecutableFile returns false, but this is expected in sandbox")
                        logger.notice("The binary has correct permissions (755) and should work when executed")
                    }
                } else {
                    logger.fault("ERROR: Wine binary not found after copy at: \(wineBinaryPath.path, privacy: .public)")
                    throw WrapperError.wineNotFound
                }
            } catch {
                logger.notice("Failed to copy wine-engine: \(error.localizedDescription, privacy: .public)")
                logger.notice("Note: The app may not have permission to read from the source directory.")
                logger.notice("Consider downloading instead or granting permission.")
                throw error
            }
            
            // Copy Frameworks from Wineskin
            let wineskinFrameworksPath = localWineskinPath.appendingPathComponent("Contents/Frameworks")
            logger.notice("Copying frameworks from \(wineskinFrameworksPath.path, privacy: .public)")
            logger.notice("               to \(frameworksDestPath.path, privacy: .public)")
            
            do {
                // Remove existing Frameworks directory if it exists
                if fileManager.fileExists(atPath: frameworksDestPath.path) {
                    try fileManager.removeItem(at: frameworksDestPath)
                }
                try fileManager.copyItem(at: wineskinFrameworksPath, to: frameworksDestPath)
            } catch {
                logger.fault("❌ Failed to copy frameworks: \(error.localizedDescription, privacy: .public)")
                logger.notice("📋 Framework copy details:")
                logger.notice("   Source: \(wineskinFrameworksPath.path, privacy: .public)")
                logger.notice("   Dest:   \(frameworksDestPath.path, privacy: .public)")
                logger.notice("   Source exists: \(FileManager.default.fileExists(atPath: wineskinFrameworksPath.path), privacy: .public)")
                logger.notice("   Source is readable: \(FileManager.default.isReadableFile(atPath: wineskinFrameworksPath.path), privacy: .public)")
                
                // List some files in source to verify structure
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: wineskinFrameworksPath.path) {
                    logger.notice("   Source contains \(contents.count, privacy: .public) items")
                    let p11Files = contents.filter { $0.contains("p11") }
                    if !p11Files.isEmpty {
                        logger.notice("   p11-related files: \(p11Files.joined(separator: ", "), privacy: .public)")
                        // Check symlink details for p11 files
                        for p11File in p11Files {
                            let filePath = wineskinFrameworksPath.appendingPathComponent(p11File)
                            if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path) {
                                let isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                                logger.notice("     - \(p11File, privacy: .public): \(isSymlink ? "symlink" : "regular file", privacy: .public)")
                                if isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: filePath.path) {
                                    logger.notice("       → \(target, privacy: .public)")
                                }
                            }
                        }
                    }
                }
                
                logger.notice("   Full error: \(error, privacy: .public)")
                if let nsError = error as NSError? {
                    logger.notice("   Domain: \(nsError.domain, privacy: .public)")
                    logger.notice("   Code: \(nsError.code, privacy: .public)")
                    logger.notice("   UserInfo: \(nsError.userInfo, privacy: .public)")
                }
                throw error
            }
            
            logger.notice("Wine framework installed successfully from local cache")
            return
        }
        
        logger.notice("Local Wine files not accessible or not found")
        
        // If local files don't exist, try downloading
        logger.notice("Local Wine files not found, attempting to download...")
        
        // Download Wine engine
        let wineEngineURL = URL(string: "https://github.com/Kegworks-App/Engines/releases/download/v1.0/WS12WineCX24.0.7.tar.xz")!
        let wineEngineCache = try await downloadAndCacheFile(url: wineEngineURL, name: "wine-engine.tar.xz")
        
        logger.notice("Wine engine downloaded/cached at: \(wineEngineCache.path, privacy: .public)")
        
        // Extract Wine engine
        let wineEngineExtracted = wineEngineCache.deletingLastPathComponent().appendingPathComponent("wine-engine")
        logger.notice("Will extract to: \(wineEngineExtracted.path, privacy: .public)")
        
        // Check if extraction exists AND is valid (has wine binary)
        let extractedWineBinary = wineEngineExtracted.appendingPathComponent("bin/wine")
        let needsExtraction = !fileManager.fileExists(atPath: extractedWineBinary.path)
        
        if needsExtraction {
            if fileManager.fileExists(atPath: wineEngineExtracted.path) {
                logger.notice("Extracted directory exists but is invalid, removing and re-extracting...")
                try fileManager.removeItem(at: wineEngineExtracted)
            } else {
                logger.notice("Extracted directory doesn't exist, extracting now...")
            }
            try await extractTarArchive(from: wineEngineCache, to: wineEngineExtracted)
            logger.notice("Extraction complete")
        } else {
            logger.notice("Using previously extracted wine-engine")
        }
        
        // Verify extracted wine exists
        guard fileManager.fileExists(atPath: extractedWineBinary.path) else {
            logger.fault("ERROR: Extracted wine binary not found at: \(extractedWineBinary.path, privacy: .public)")
            throw WrapperError.wineNotFound
        }
        logger.notice("Verified extracted wine binary at: \(extractedWineBinary.path, privacy: .public)")
        
        // Copy Wine to wrapper
        logger.notice("Copying extracted wine to wrapper at: \(wineDestPath.path, privacy: .public)")
        
        // Ensure parent directory exists
        try fileManager.createDirectory(at: wineDestPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        try fileManager.copyItem(at: wineEngineExtracted, to: wineDestPath)
        
        // Verify Wine binary exists in wrapper
        let wrapperWineBinary = wineDestPath.appendingPathComponent("bin/wine")
        guard fileManager.fileExists(atPath: wrapperWineBinary.path) else {
            logger.fault("ERROR: Wine binary not found in wrapper at: \(wrapperWineBinary.path, privacy: .public)")
            throw WrapperError.wineNotFound
        }
        
        logger.notice("Wine engine installed successfully")
        
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
            logger.notice("Removing existing Frameworks directory...")
            try fileManager.removeItem(at: frameworksDestPath)
        }
        
        logger.notice("Copying Frameworks from Wineskin...")
        do {
            try fileManager.copyItem(at: wineskinFrameworksPath, to: frameworksDestPath)
        } catch {
            logger.fault("❌ Failed to copy frameworks: \(error.localizedDescription, privacy: .public)")
            logger.notice("📋 Framework copy details:")
            logger.notice("   Source: \(wineskinFrameworksPath.path, privacy: .public)")
            logger.notice("   Dest:   \(frameworksDestPath.path, privacy: .public)")
            logger.notice("   Source exists: \(FileManager.default.fileExists(atPath: wineskinFrameworksPath.path), privacy: .public)")
            logger.notice("   Source is readable: \(FileManager.default.isReadableFile(atPath: wineskinFrameworksPath.path), privacy: .public)")
            
            // List some files in source to verify structure
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: wineskinFrameworksPath.path) {
                logger.notice("   Source contains \(contents.count, privacy: .public) items")
                let p11Files = contents.filter { $0.contains("p11") }
                if !p11Files.isEmpty {
                    logger.notice("   p11-related files: \(p11Files.joined(separator: ", "), privacy: .public)")
                    // Check symlink details for p11 files
                    for p11File in p11Files {
                        let filePath = wineskinFrameworksPath.appendingPathComponent(p11File)
                        if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path) {
                            let isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                            logger.notice("     - \(p11File, privacy: .public): \(isSymlink ? "symlink" : "regular file", privacy: .public)")
                            if isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: filePath.path) {
                                logger.notice("       → \(target, privacy: .public)")
                            }
                        }
                    }
                }
            }
            
            logger.notice("   Full error: \(error, privacy: .public)")
            if let nsError = error as NSError? {
                logger.notice("   Domain: \(nsError.domain, privacy: .public)")
                logger.notice("   Code: \(nsError.code, privacy: .public)")
                logger.notice("   UserInfo: \(nsError.userInfo, privacy: .public)")
            }
            throw error
        }
        
        logger.notice("Wineskin frameworks installed successfully")
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
        
        logger.notice("Fixing rpaths in Wine binaries to: \(rpathToFrameworks, privacy: .public)")
        
        // Get all binaries in bin directory
        guard let binContents = try? fileManager.contentsOfDirectory(at: binPath, includingPropertiesForKeys: nil) else {
            logger.error("Warning: Could not read wine bin directory")
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
                        logger.error("Warning: Failed to fix rpath for \(binaryURL.lastPathComponent, privacy: .public): \(errorStr, privacy: .public)")
                        failedCount += 1
                    }
                }
            } catch {
                logger.error("Warning: Could not run install_name_tool on \(binaryURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                failedCount += 1
            }
        }
        
        logger.notice("Fixed rpaths in \(fixedCount, privacy: .public) Wine binaries (\(failedCount, privacy: .public) failed)")
    }
    
    /// Create the main launcher executable
    private func createLauncherExecutable(at macOSPath: URL, wrapperPath: URL) throws {
        let launcherPath = macOSPath.appendingPathComponent("GameWrapper")
        
        // Get path to Swift runtime source in the wrapper's Resources
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        let runtimeSourcePath = resourcesPath.appendingPathComponent("GameWrapperRuntime/main.swift")
        let sharedSourcePath = resourcesPath.appendingPathComponent("GameWrapperRuntime/WineEnvironment.swift")
        
        // If we have the Swift runtime source, compile it
        if fileManager.fileExists(atPath: runtimeSourcePath.path) {
            logger.notice("Compiling Swift runtime...")
            Task { await EventBus.app.publishInstallation(.progress(.configuringWrapper(substep: "Compiling Swift runtime"))) }
            
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
                logger.fault("❌ Swift compilation failed: \(errorMessage, privacy: .public)")
                throw WrapperError.swiftCompilationFailed(errorMessage)
            } else {
                logger.notice("✅ Created Swift launcher executable: GameWrapper")
                
                // Code sign the launcher executable
                // Ad-hoc signing is sufficient for local development
                logger.notice("Signing launcher executable...")
                Task { await EventBus.app.publishInstallation(.progress(.configuringWrapper(substep: "Signing launcher executable"))) }
                let codesignPath = "/usr/bin/codesign"
                let signProcess = Process()
                signProcess.executableURL = URL(fileURLWithPath: codesignPath)
                signProcess.arguments = [
                    "-s", "-",  // Ad-hoc signing
                    "--force",
                    launcherPath.path
                ]
                
                let signOutputPipe = Pipe()
                let signErrorPipe = Pipe()
                signProcess.standardOutput = signOutputPipe
                signProcess.standardError = signErrorPipe
                
                try signProcess.run()
                signProcess.waitUntilExit()
                
                if signProcess.terminationStatus == 0 {
                    logger.notice("✅ Signed launcher executable")
                } else {
                    let errorData = signErrorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    let command = "\(codesignPath) \(signProcess.arguments?.joined(separator: " ") ?? "")"
                    logger.error("⚠️ Warning: Failed to sign launcher: \(errorMessage, privacy: .public)")
                    logger.notice("   Command: \(command, privacy: .public)")
                    logger.notice("The wrapper may not run on some systems")
                    // Don't throw an error - continue anyway
                }
            }
        } else {
            logger.fault("❌ Swift runtime source not found at \(runtimeSourcePath.path, privacy: .public)")
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
        
        logger.notice("Created bash launcher executable: GameWrapper")
    }
    
    /// Download and cache a file using URLSession with progress reporting
    private func downloadAndCacheFile(url: URL, name: String) async throws -> URL {
        let cacheDir = fileManager.temporaryDirectory.appendingPathComponent("SecondChance/Downloads")
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let cachePath = cacheDir.appendingPathComponent(name)
        
        // Return cached file if it exists
        if fileManager.fileExists(atPath: cachePath.path) {
            logger.notice("Using cached file: \(name, privacy: .public)")
            return cachePath
        }
        
        logger.notice("Downloading \(name, privacy: .public) from \(url.absoluteString, privacy: .public)...")
        
        // Create a URLSession with a delegate to track progress
        let delegate = DownloadDelegate(fileName: name)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        
        let (downloadedFileURL, response) = try await session.download(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WrapperError.downloadFailed
        }
        
        try fileManager.moveItem(at: downloadedFileURL, to: cachePath)
        
        logger.notice("Downloaded \(name, privacy: .public) successfully")
        return cachePath
    }
    
    /// URLSessionDownloadDelegate to track download progress
    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let fileName: String
        var lastPrintedProgress: Int = -1
        private let logger = Logger(subsystem: "com.secondchance", category: "WrapperBuilder.DownloadDelegate")
        
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
                let downloadDesc = String(format: "Downloading %@: %.1f / %.1f MB (%d%%)", self.fileName, mbWritten, mbTotal, progress)
                logger.notice("\(downloadDesc, privacy: .public)")
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
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xf", source.path, "-C", tempDestination.path, "--strip-components=1"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.notice("Extraction error: \(errorMessage, privacy: .public)")
            throw WrapperError.extractionFailed(errorMessage)
        }
        
        logger.notice("Extraction completed, moving to final location...")
        
        // Move to final destination
        try fileManager.moveItem(at: tempDestination, to: destination)
        
        logger.notice("Extracted to \(destination.path, privacy: .public)")
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
        
        Task { await EventBus.app.publishInstallation(.progress(.copyingInstaller(substep: nil))) }
        
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let installerPath = driveCPath.appendingPathComponent("nancy-drew-installer")
        
        try fileManager.createDirectory(at: installerPath, withIntermediateDirectories: true)
        
        // Copy disk 1 on background queue
        let disk1Dest = installerPath.appendingPathComponent("disk-1")
        try await Task.detached {
            try FileManager.default.copyItem(at: disk1, to: disk1Dest)
        }.value
        
        // Remove extended attributes, resource forks, and Finder info that would cause codesign to fail
        try removeExtendedAttributes(from: disk1Dest)
        
        // Copy disk 2 if present
        if let disk2 = disk2 {
            let disk2Dest = installerPath.appendingPathComponent("disk-2")
            try await Task.detached {
                try FileManager.default.copyItem(at: disk2, to: disk2Dest)
            }.value
            
            // Remove extended attributes from disk 2 as well
            try removeExtendedAttributes(from: disk2Dest)
            
            // Create combined disk directory with symlinks
            let combinedDest = installerPath.appendingPathComponent("disk-combined")
            try fileManager.createDirectory(at: combinedDest, withIntermediateDirectories: true)
            
            // Symlink contents from both disks
            let disksToLink = [disk1Dest, disk2Dest]
            for diskDest in disksToLink {
                let diskName = diskDest.lastPathComponent
                let diskContents = try fileManager.contentsOfDirectory(at: diskDest, includingPropertiesForKeys: nil)
                for item in diskContents {
                    let fileName = item.lastPathComponent
                    
                    // Skip .DS_Store files - codesign will fail if it tries to sign a .DS_Store symlink
                    if fileName == ".DS_Store" {
                        continue
                    }
                    
                    let linkPath = combinedDest.appendingPathComponent(fileName)
                    // Don't overwrite existing links (disk-1 has priority)
                    if !fileManager.fileExists(atPath: linkPath.path) {
                        let relativePath = "../\(diskName)/\(fileName)"
                        try fileManager.createSymbolicLink(atPath: linkPath.path, withDestinationPath: relativePath)
                    }
                }
            }
        }
        
        // Copy setup.iss file if it exists for this game
        if let issPath = Bundle.main.path(forResource: gameSlug, ofType: "iss", inDirectory: "installer-answer-files") {
            let setupIssDestPath = installerPath.appendingPathComponent("setup.iss")
            do {
                try fileManager.copyItem(atPath: issPath, toPath: setupIssDestPath.path)
                logger.notice("✅ Copied setup.iss for \(gameSlug, privacy: .public)")
            } catch {
                logger.error("⚠️ Failed to copy setup.iss: \(error, privacy: .public)")
            }
        } else {
            logger.notice("ℹ️ No setup.iss file found for \(gameSlug, privacy: .public)")
        }
        
        // Mount the disk directories as CD-ROM drives
        // (Don't report progress again - would cause duplicate print)
        try await mountGameDisksIntoWine(wrapperPath: wrapperPath)
        
        // Save to cache
        try cacheManager.saveCache(wrapperPath: wrapperPath, stage: .diskGameInstallerCopied, gameSlug: gameSlug)
    }
    
    /// Mount game disk directories as CD-ROM drives
    private func mountGameDisksIntoWine(wrapperPath: URL) async throws {
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let installerPath = driveCPath.appendingPathComponent("nancy-drew-installer")
        
        // Find all disk-* directories and sort them
        guard let contents = try? fileManager.contentsOfDirectory(at: installerPath, includingPropertiesForKeys: [.isDirectoryKey]) else {
            logger.notice("No installer directory found, skipping disk mounting")
            return
        }
        
        var diskDirs: [(number: Int, url: URL)] = []
        for item in contents {
            let name = item.lastPathComponent
            if name.hasPrefix("disk-"),
               let diskNumber = Int(name.dropFirst(5)) { // Skip "disk-"
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    diskDirs.append((number: diskNumber, url: item))
                }
            }
        }
        
        diskDirs.sort { $0.number < $1.number }
        
        if diskDirs.isEmpty {
            logger.notice("No disk directories found to mount")
            return
        }
        
        logger.notice("Found \(diskDirs.count, privacy: .public) disk director\(diskDirs.count == 1 ? "y" : "ies", privacy: .public) to mount as CD-ROM drives")
        
        // Mount each disk starting at drive letter "d:" (4th letter, index 3)
        for (index, disk) in diskDirs.enumerated() {
            let letterIndex = index + 3 // Start at "d:" which is the 4th letter (index 3)
            guard letterIndex < 26 else {
                logger.error("Warning: Too many disks to mount (maximum 23)")
                break
            }
            
            let letter = String(Character(UnicodeScalar(UInt8(97 + letterIndex)))) // 'a' = 97
            
            // Use relative path from prefix directory
            let relativePath = "../drive_c/nancy-drew-installer/disk-\(disk.number)"
            
            logger.notice("Mounting disk-\(disk.number, privacy: .public) as \(letter, privacy: .public): (cdrom)")
            try await wineManager.mountDirectory(
                relativePath,
                asDrive: letter,
                type: "cdrom",
                in: wrapperPath
            )
        }
    }
    
    /// Install Steam client in wrapper
    func installSteamClient(in wrapperPath: URL) async throws {
        // Check cache first
        if let _ = try cacheManager.restoreCache(stage: .steamClientInstalled, to: wrapperPath) {
            return
        }
        
        Task { await EventBus.app.publishInstallation(.progress(.installingGame(substep: "Installing Steam client"))) }
        
        // Stop wine server first
        let wine = WineEnvironment(appPath: wrapperPath)
        _ = wine.stopWineserver()
        
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
        Task { await EventBus.app.publishInstallation(.progress(.configuringWrapper(substep: "Updating configuration files"))) }
        
        let infoPlistPath = wrapperPath.appendingPathComponent("Contents/Info.plist")
        
        // Update Info.plist
        guard let plistData = try? Data(contentsOf: infoPlistPath),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw WrapperError.invalidInfoPlist
        }
        
        // Update bundle identifier by replacing GameWrapper with game ID
        guard let currentBundleID = plist["CFBundleIdentifier"] as? String else {
            throw WrapperError.invalidInfoPlist
        }
        
        guard currentBundleID.contains("GameWrapper") else {
            throw WrapperError.invalidInfoPlist
        }
        
        let newBundleID = currentBundleID.replacingOccurrences(of: "GameWrapper", with: "nancy-drew." + gameInfo.id)
        plist["CFBundleIdentifier"] = newBundleID
        plist["CFBundleName"] = "Nancy Drew - \(gameInfo.title)"
        plist["CFBundleDisplayName"] = "Nancy Drew - \(gameInfo.title)"
        plist["GameExePath"] = gameExePath
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
        
        // Remap documents folder to point to a namespaced dir in the user's Application Support
        // dir on the host computer. This documents symlink will likely be replaced with a more direct link when running
        // the game wrapper but we set this one up in case it's run on a read-only system.
        let prefixPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix")
        let driveCPath = prefixPath.appendingPathComponent("drive_c")
        let documentsPath = driveCPath.appendingPathComponent("/users/\(WineEnvironment.wineUsername)/Documents")
        
        // Remove existing Documents directory/symlink if it exists
        try? FileManager.default.removeItem(at: documentsPath)
        
        // Get where the a: drive symlink points to
        let dosdeviceAPath = prefixPath.appendingPathComponent("dosdevices/a:")
        let aDestination = try FileManager.default.destinationOfSymbolicLink(atPath: dosdeviceAPath.path)
        
        // Create symlink from Documents to the same destination as a: drive
        try FileManager.default.createSymbolicLink(
            atPath: documentsPath.path,
            withDestinationPath: aDestination
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
            "GameSlug": gameInfo.id,
            "GameInstallerDir": installerDir
        ]
        
        // Add Steam ID if present
        if let steamID = steamID {
            settings["SteamGameId"] = steamID
        }
        
        // Write plist
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        try data.write(to: appSettingsPath)
        
        logger.notice("Created AppSettings.plist with engine: \(gameEngine, privacy: .public)")
    }
    
    /// Configure game INI files
    private func configureGameINI(at wrapperPath: URL, gameExePath: String) throws {
        // Build the full path to the game directory within the wrapper
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        
        // gameExePath is a Windows path like "/Program Files (x86)/Nancy Drew/Game/game.exe"
        // Remove leading slash and append to drive_c
        let cleanGameExePath = gameExePath.hasPrefix("/") ? String(gameExePath.dropFirst()) : gameExePath
        let gameExeURL = driveCPath.appendingPathComponent(cleanGameExePath)
        let gameDir = gameExeURL.deletingLastPathComponent()
        
        logger.notice("Configuring game INI files in: \(gameDir.path, privacy: .public)")
        
        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gameDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("⚠️ Warning: Game directory not found at: \(gameDir.path, privacy: .public)")
            
            // Trace the path from C drive to help debug
            DebugUtils.tracePath(from: driveCPath, to: gameDir, fileManager: fileManager)
            return
        }
        
        // Find INI files in game directory
        let contents = try? fileManager.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: nil,
            options: []
        )
        
        guard let contents = contents else {
            logger.error("⚠️ Warning: Failed to read game directory at: \(gameDir.path, privacy: .public)")
            return
        }
        
        let iniFiles = contents.filter({ $0.pathExtension.lowercased() == "ini" })
        
        if iniFiles.isEmpty {
            logger.error("⚠️ No INI files found in game directory")
            logger.notice("   Files found in directory:")
            for file in contents {
                logger.notice("     - \(file.lastPathComponent, privacy: .public)")
            }
            return
        }
        
        logger.notice("Found \(iniFiles.count, privacy: .public) INI file\(iniFiles.count == 1 ? "" : "s", privacy: .public) to configure")
        
        for iniFile in iniFiles {
            logger.notice("  Processing: \(iniFile.lastPathComponent, privacy: .public)")
            
            guard let originalContent = try? String(contentsOf: iniFile, encoding: .utf8) else {
                logger.error("    ⚠️ Failed to read file")
                continue
            }
            
            var content = originalContent
            var modified = false
            
            // Set LCD mode (WindowMode=2)
            let windowModeChanged = content.contains("WindowMode=0")
            if windowModeChanged {
                content = content.replacingOccurrences(of: "WindowMode=0", with: "WindowMode=2")
                logger.notice("    ✅ Set WindowMode to 2 (LCD mode)")
                modified = true
            } else if content.contains("WindowMode=2") {
                logger.notice("    ℹ️ WindowMode already set to 2")
            } else {
                logger.notice("    ℹ️ No WindowMode setting found")
            }
            
            // Set save path to Documents
            let savePath = "LoadSavePath=\\\\users\\\\crossover\\\\Documents"
            let savePathPattern = #"LoadSavePath=.*"#
            if let regex = try? NSRegularExpression(pattern: savePathPattern, options: []),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                let oldValue = String(content[Range(match.range, in: content)!])
                content = regex.stringByReplacingMatches(
                    in: content,
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: savePath
                )
                logger.notice("    ✅ Updated LoadSavePath")
                logger.notice("       Old: \(oldValue, privacy: .public)")
                logger.notice("       New: \(savePath, privacy: .public)")
                modified = true
            } else {
                logger.notice("    ℹ️ No LoadSavePath setting found")
            }
            
            // Write back if modified
            if modified {
                do {
                    try content.write(to: iniFile, atomically: true, encoding: .utf8)
                    logger.notice("    ✅ Saved changes to \(iniFile.lastPathComponent, privacy: .public)")
                } catch {
                    logger.error("    ⚠️ Failed to save changes: \(error, privacy: .public)")
                }
            } else {
                logger.notice("    ℹ️ No changes needed")
            }
        }
    }
    
    /// Remove extended attributes, resource forks, and Finder info from a directory
    /// This prevents codesign errors like "resource fork, Finder information, or similar detritus not allowed"
    private func removeExtendedAttributes(from path: URL) throws {
        logger.notice("Removing extended attributes from \(path.lastPathComponent, privacy: .public)...")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", path.path]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.error("⚠️ Failed to remove extended attributes: \(errorMessage, privacy: .public)")
            // Don't throw - this is not critical, codesign will just fail later with a better message
        }
    }
    
    /// Sign the wrapper app
    func signWrapper(at path: URL) throws {
        logger.notice("Signing wrapper...")
        
        let codesignPath = "/usr/bin/codesign"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codesignPath)
        process.arguments = [
            "--force",
            "--sign", "-",
            "--verbose=2",
            path.path
        ]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            logger.notice("✅ Wrapper signed successfully")
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            let command = "\(codesignPath) \(process.arguments?.joined(separator: " ") ?? "")"
            logger.error("⚠️ Code signing failed: \(errorMessage, privacy: .public)")
            logger.notice("   Command: \(command, privacy: .public)")
            throw WrapperError.signingFailed(errorMessage)
        }
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
    case copyFailed(message: String, command: String?, output: String?)
    case signingFailed(String)
    
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
        case .copyFailed(let message, _, _):
            return "Failed to copy files: \(message)"
        case .signingFailed(let message):
            return "Code signing failed: \(message)"
        }
    }
    
    /// The command that produced this error, if any.
    var copyCommand: String? {
        if case let .copyFailed(_, command, _) = self { return command }
        return nil
    }
    
    /// The raw command output (e.g. stderr) attached to this error, if any.
    var copyOutput: String? {
        if case let .copyFailed(_, _, output) = self { return output }
        return nil
    }
}
