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
        
        print("Creating unified wrapper with both Wine and ScummVM support...")
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
                print("Copy output: \(output)")
            }
            print("❌ Failed to copy GameWrapper template: \(error.localizedDescription)")
            if let wrapperError = error as? WrapperError, let command = wrapperError.copyCommand {
                print("   Command: \(command)")
            }
            print("📋 Template copy details:")
            print("   Source: \(templatePath.path)")
            print("   Dest:   \(path.path)")
            
            // Check the Frameworks in the template
            let templateFrameworks = templatePath.appendingPathComponent("Contents/Frameworks")
            if let contents = try? fileManager.contentsOfDirectory(atPath: templateFrameworks.path) {
                print("   Template Frameworks contains \(contents.count) items")
                let p11Files = contents.filter { $0.contains("p11") }
                if !p11Files.isEmpty {
                    print("   p11-related files in template: \(p11Files.joined(separator: ", "))")
                    for p11File in p11Files {
                        let filePath = templateFrameworks.appendingPathComponent(p11File)
                        if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path) {
                            let isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                            print("     - \(p11File): \(isSymlink ? "symlink" : "regular file")")
                            if isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: filePath.path) {
                                print("       → \(target)")
                                // Check if target exists
                                let targetPath = templateFrameworks.appendingPathComponent(target)
                                let targetExists = fileManager.fileExists(atPath: targetPath.path)
                                print("       Target exists: \(targetExists)")
                                if targetExists, let targetAttrs = try? fileManager.attributesOfItem(atPath: targetPath.path) {
                                    let targetIsSymlink = targetAttrs[.type] as? FileAttributeType == .typeSymbolicLink
                                    if targetIsSymlink, let nextTarget = try? fileManager.destinationOfSymbolicLink(atPath: targetPath.path) {
                                        print("       Target is also symlink → \(nextTarget)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            print("   Full error: \(error)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
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
        print("Cleaning up unused game engine from wrapper...")
        
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        
        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            // Using Wine, remove ScummVM files listed in scummvm-files
            let scummvmFilesPath = resourcesPath.appendingPathComponent("scummvm-files")
            if fileManager.fileExists(atPath: scummvmFilesPath.path) {
                print("Reading ScummVM files list...")
                if let content = try? String(contentsOf: scummvmFilesPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    print("Found \(lines.count) ScummVM files/directories to remove")
                    
                    for relativePath in lines {
                        let pathToRemove = wrapperPath.appendingPathComponent(relativePath)
                        if fileManager.fileExists(atPath: pathToRemove.path) {
                            try fileManager.removeItem(at: pathToRemove)
                        }
                    }
                }
            } else {
                print("Warning: scummvm-files list not found at \(scummvmFilesPath.path)")
            }
            
        case .scummvm:
            // Using ScummVM, remove Wine files listed in wine-files
            let wineFilesPath = resourcesPath.appendingPathComponent("wine-files")
            if fileManager.fileExists(atPath: wineFilesPath.path) {
                print("Reading Wine files list...")
                if let content = try? String(contentsOf: wineFilesPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    print("Found \(lines.count) Wine files/directories to remove")
                    
                    for relativePath in lines {
                        let pathToRemove = wrapperPath.appendingPathComponent(relativePath)
                        if fileManager.fileExists(atPath: pathToRemove.path) {
                            try fileManager.removeItem(at: pathToRemove)
                        }
                    }
                }
            } else {
                print("Warning: wine-files list not found at \(wineFilesPath.path)")
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
                print("❌ Failed to copy frameworks: \(error.localizedDescription)")
                print("📋 Framework copy details:")
                print("   Source: \(wineskinFrameworksPath.path)")
                print("   Dest:   \(frameworksDestPath.path)")
                print("   Source exists: \(fileManager.fileExists(atPath: wineskinFrameworksPath.path))")
                print("   Source is readable: \(fileManager.isReadableFile(atPath: wineskinFrameworksPath.path))")
                
                // List some files in source to verify structure
                if let contents = try? fileManager.contentsOfDirectory(atPath: wineskinFrameworksPath.path) {
                    print("   Source contains \(contents.count) items")
                    let p11Files = contents.filter { $0.contains("p11") }
                    if !p11Files.isEmpty {
                        print("   p11-related files: \(p11Files.joined(separator: ", "))")
                        // Check symlink details for p11 files
                        for p11File in p11Files {
                            let filePath = wineskinFrameworksPath.appendingPathComponent(p11File)
                            if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path) {
                                let isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                                print("     - \(p11File): \(isSymlink ? "symlink" : "regular file")")
                                if isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: filePath.path) {
                                    print("       → \(target)")
                                }
                            }
                        }
                    }
                }
                
                print("   Full error: \(error)")
                if let nsError = error as NSError? {
                    print("   Domain: \(nsError.domain)")
                    print("   Code: \(nsError.code)")
                    print("   UserInfo: \(nsError.userInfo)")
                }
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
        do {
            try fileManager.copyItem(at: wineskinFrameworksPath, to: frameworksDestPath)
        } catch {
            print("❌ Failed to copy frameworks: \(error.localizedDescription)")
            print("📋 Framework copy details:")
            print("   Source: \(wineskinFrameworksPath.path)")
            print("   Dest:   \(frameworksDestPath.path)")
            print("   Source exists: \(fileManager.fileExists(atPath: wineskinFrameworksPath.path))")
            print("   Source is readable: \(fileManager.isReadableFile(atPath: wineskinFrameworksPath.path))")
            
            // List some files in source to verify structure
            if let contents = try? fileManager.contentsOfDirectory(atPath: wineskinFrameworksPath.path) {
                print("   Source contains \(contents.count) items")
                let p11Files = contents.filter { $0.contains("p11") }
                if !p11Files.isEmpty {
                    print("   p11-related files: \(p11Files.joined(separator: ", "))")
                    // Check symlink details for p11 files
                    for p11File in p11Files {
                        let filePath = wineskinFrameworksPath.appendingPathComponent(p11File)
                        if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path) {
                            let isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                            print("     - \(p11File): \(isSymlink ? "symlink" : "regular file")")
                            if isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: filePath.path) {
                                print("       → \(target)")
                            }
                        }
                    }
                }
            }
            
            print("   Full error: \(error)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            throw error
        }
        
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
    
    /// Create the main launcher executable
    private func createLauncherExecutable(at macOSPath: URL, wrapperPath: URL) throws {
        let launcherPath = macOSPath.appendingPathComponent("GameWrapper")
        
        // Get path to Swift runtime source in the wrapper's Resources
        let resourcesPath = wrapperPath.appendingPathComponent("Contents/Resources")
        let runtimeSourcePath = resourcesPath.appendingPathComponent("GameWrapperRuntime/main.swift")
        let sharedSourcePath = resourcesPath.appendingPathComponent("GameWrapperRuntime/WineEnvironment.swift")
        
        // If we have the Swift runtime source, compile it
        if fileManager.fileExists(atPath: runtimeSourcePath.path) {
            print("Compiling Swift runtime...")
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
                print("❌ Swift compilation failed: \(errorMessage)")
                throw WrapperError.swiftCompilationFailed(errorMessage)
            } else {
                print("✅ Created Swift launcher executable: GameWrapper")
                
                // Code sign the launcher executable
                // Ad-hoc signing is sufficient for local development
                print("Signing launcher executable...")
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
                    print("✅ Signed launcher executable")
                } else {
                    let errorData = signErrorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    let command = "\(codesignPath) \(signProcess.arguments?.joined(separator: " ") ?? "")"
                    print("⚠️ Warning: Failed to sign launcher: \(errorMessage)")
                    print("   Command: \(command)")
                    print("The wrapper may not run on some systems")
                    // Don't throw an error - continue anyway
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
                print("✅ Copied setup.iss for \(gameSlug)")
            } catch {
                print("⚠️ Failed to copy setup.iss: \(error)")
            }
        } else {
            print("ℹ️ No setup.iss file found for \(gameSlug)")
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
            print("No installer directory found, skipping disk mounting")
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
            print("No disk directories found to mount")
            return
        }
        
        print("Found \(diskDirs.count) disk director\(diskDirs.count == 1 ? "y" : "ies") to mount as CD-ROM drives")
        
        // Mount each disk starting at drive letter "d:" (4th letter, index 3)
        for (index, disk) in diskDirs.enumerated() {
            let letterIndex = index + 3 // Start at "d:" which is the 4th letter (index 3)
            guard letterIndex < 26 else {
                print("Warning: Too many disks to mount (maximum 23)")
                break
            }
            
            let letter = String(Character(UnicodeScalar(UInt8(97 + letterIndex)))) // 'a' = 97
            
            // Use relative path from prefix directory
            let relativePath = "../drive_c/nancy-drew-installer/disk-\(disk.number)"
            
            print("Mounting disk-\(disk.number) as \(letter): (cdrom)")
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
        
        print("Created AppSettings.plist with engine: \(gameEngine)")
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
        
        print("Configuring game INI files in: \(gameDir.path)")
        
        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gameDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("⚠️ Warning: Game directory not found at: \(gameDir.path)")
            
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
            print("⚠️ Warning: Failed to read game directory at: \(gameDir.path)")
            return
        }
        
        let iniFiles = contents.filter({ $0.pathExtension.lowercased() == "ini" })
        
        if iniFiles.isEmpty {
            print("⚠️ No INI files found in game directory")
            print("   Files found in directory:")
            for file in contents {
                print("     - \(file.lastPathComponent)")
            }
            return
        }
        
        print("Found \(iniFiles.count) INI file\(iniFiles.count == 1 ? "" : "s") to configure")
        
        for iniFile in iniFiles {
            print("  Processing: \(iniFile.lastPathComponent)")
            
            guard let originalContent = try? String(contentsOf: iniFile, encoding: .utf8) else {
                print("    ⚠️ Failed to read file")
                continue
            }
            
            var content = originalContent
            var modified = false
            
            // Set LCD mode (WindowMode=2)
            let windowModeChanged = content.contains("WindowMode=0")
            if windowModeChanged {
                content = content.replacingOccurrences(of: "WindowMode=0", with: "WindowMode=2")
                print("    ✅ Set WindowMode to 2 (LCD mode)")
                modified = true
            } else if content.contains("WindowMode=2") {
                print("    ℹ️ WindowMode already set to 2")
            } else {
                print("    ℹ️ No WindowMode setting found")
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
                print("    ✅ Updated LoadSavePath")
                print("       Old: \(oldValue)")
                print("       New: \(savePath)")
                modified = true
            } else {
                print("    ℹ️ No LoadSavePath setting found")
            }
            
            // Write back if modified
            if modified {
                do {
                    try content.write(to: iniFile, atomically: true, encoding: .utf8)
                    print("    ✅ Saved changes to \(iniFile.lastPathComponent)")
                } catch {
                    print("    ⚠️ Failed to save changes: \(error)")
                }
            } else {
                print("    ℹ️ No changes needed")
            }
        }
    }
    
    /// Remove extended attributes, resource forks, and Finder info from a directory
    /// This prevents codesign errors like "resource fork, Finder information, or similar detritus not allowed"
    private func removeExtendedAttributes(from path: URL) throws {
        print("Removing extended attributes from \(path.lastPathComponent)...")
        
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
            print("⚠️ Failed to remove extended attributes: \(errorMessage)")
            // Don't throw - this is not critical, codesign will just fail later with a better message
        }
    }
    
    /// Sign the wrapper app
    func signWrapper(at path: URL) throws {
        print("Signing wrapper...")
        
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
            print("✅ Wrapper signed successfully")
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            let command = "\(codesignPath) \(process.arguments?.joined(separator: " ") ?? "")"
            print("⚠️ Code signing failed: \(errorMessage)")
            print("   Command: \(command)")
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
