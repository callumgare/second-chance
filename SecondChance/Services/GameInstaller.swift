//
//  GameInstaller.swift
//  SecondChance
//
//  Orchestrates the complete game installation process

import Foundation
import AppKit

/// Installer types for different game installers
enum InstallerType {
    case msi
    case installShield
    case innoSetup
    case unknown
}

/// Orchestrates the complete Nancy Drew game installation process
class GameInstaller {
    static let shared = GameInstaller()
    
    private let fileManager = FileManager.default
    private let wineManager = WineManager.shared
    private let wrapperBuilder = WrapperBuilder.shared
    private let gameDetector = GameDetector.shared
    private let gameInfoProvider = GameInfoProvider.shared
    private let exiftool = ExiftoolService.shared
    
    private init() {}
    
    // MARK: - Main Installation Flow
    
    /// Install game from disks
    func installFromDisk(
        disk1Path: URL,
        disk2Path: URL?,
        progressHandler: @escaping (InstallationState) -> Void
    ) async throws -> URL {
        let tracker = ProgressTracker()
        
        // Detect game
        progressHandler(.detectingGame(substep: nil, elapsedSeconds: nil))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.detectingGame(substep: nil, elapsedSeconds: elapsed))
            }
        }
        let gameSlug = try await gameDetector.detectGame(fromDisk: disk1Path)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        print("Detected game: \(gameInfo.title)")
        _ = await tracker.stop()
        
        // Create wrapper
        progressHandler(.settingUpWrapper(substep: nil, elapsedSeconds: 0))
        var currentSubstep: String?
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.settingUpWrapper(substep: currentSubstep, elapsedSeconds: elapsed))
            }
        }
        let wrapperPath = createTemporaryWrapperPath()
        print("📦 Temporary wrapper location: \(wrapperPath.path)")
        try await wrapperBuilder.createBaseWrapper(at: wrapperPath) { substep in
            currentSubstep = substep
            Task { @MainActor in
                let elapsed = await tracker.currentElapsed()
                progressHandler(.settingUpWrapper(substep: substep, elapsedSeconds: elapsed))
            }
        }
        _ = await tracker.stop()
        
        // Copy installer
        progressHandler(.copyingInstaller(substep: nil, elapsedSeconds: 0))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.copyingInstaller(substep: nil, elapsedSeconds: elapsed))
            }
        }
        try await wrapperBuilder.copyGameDisks(
            disk1: disk1Path,
            disk2: disk2Path,
            to: wrapperPath,
            gameSlug: gameSlug
        )
        _ = await tracker.stop()
        
        // Install game
        progressHandler(.installingGame(substep: nil, elapsedSeconds: 0))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.installingGame(substep: nil, elapsedSeconds: elapsed))
            }
        }
        let gameExePath: String
        let installerDir: String
        
        if gameInfo.gameEngine == .wine {
            (gameExePath, installerDir) = try await installGameWithWine(
                wrapperPath: wrapperPath,
                gameInfo: gameInfo
            )
        } else if gameInfo.gameEngine == .scummvm {
            (gameExePath, installerDir) = try await installGameWithScummVM(
                wrapperPath: wrapperPath,
                gameInfo: gameInfo
            )
        } else {
            throw InstallationError.unsupportedEngine
        }
        _ = await tracker.stop()
        
        // Clean up unused engine
        try wrapperBuilder.cleanupUnusedEngine(at: wrapperPath, gameEngine: gameInfo.gameEngine)
        
        // Configure wrapper
        progressHandler(.configuringWrapper(substep: nil, elapsedSeconds: 0))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.configuringWrapper(substep: nil, elapsedSeconds: elapsed))
            }
        }
        try wrapperBuilder.configureWrapper(
            at: wrapperPath,
            gameInfo: gameInfo,
            gameExePath: gameExePath,
            installerDir: installerDir
        )
        _ = await tracker.stop()
        
        return wrapperPath
    }
    
    /// Install game from Her Interactive installer
    func installFromHerDownload(
        installerPath: URL,
        progressHandler: @escaping (InstallationState) -> Void
    ) async throws -> URL {
        let tracker = ProgressTracker()
        
        // Detect game
        progressHandler(.detectingGame(substep: nil, elapsedSeconds: nil))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.detectingGame(substep: nil, elapsedSeconds: elapsed))
            }
        }
        let gameSlug = try await gameDetector.detectGame(fromInstaller: installerPath)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        print("Detected game: \(gameInfo.title)")
        _ = await tracker.stop()
        
        // Create wrapper
        progressHandler(.settingUpWrapper(substep: nil, elapsedSeconds: 0))
        var currentSubstep: String?
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.settingUpWrapper(substep: currentSubstep, elapsedSeconds: elapsed))
            }
        }
        let wrapperPath = createTemporaryWrapperPath()
        print("📦 Temporary wrapper location: \(wrapperPath.path)")
        try await wrapperBuilder.createBaseWrapper(at: wrapperPath) { substep in
            currentSubstep = substep
            Task { @MainActor in
                let elapsed = await tracker.currentElapsed()
                progressHandler(.settingUpWrapper(substep: substep, elapsedSeconds: elapsed))
            }
        }
        _ = await tracker.stop()
        
        // Install game
        progressHandler(.installingGame(substep: nil, elapsedSeconds: 0))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.installingGame(substep: nil, elapsedSeconds: elapsed))
            }
        }
        let (gameExePath, installerDir) = try await installGameWithWine(
            wrapperPath: wrapperPath,
            gameInfo: gameInfo,
            installerPath: installerPath
        )
        _ = await tracker.stop()
        
        // Clean up unused engine
        try wrapperBuilder.cleanupUnusedEngine(at: wrapperPath, gameEngine: gameInfo.gameEngine)
        
        // Configure wrapper
        progressHandler(.configuringWrapper(substep: nil, elapsedSeconds: 0))
        await tracker.start { elapsed in
            Task { @MainActor in
                progressHandler(.configuringWrapper(substep: nil, elapsedSeconds: elapsed))
            }
        }
        try wrapperBuilder.configureWrapper(
            at: wrapperPath,
            gameInfo: gameInfo,
            gameExePath: gameExePath,
            installerDir: installerDir
        )
        _ = await tracker.stop()
        
        return wrapperPath
    }
    
    /// Install game from Steam
    func installFromSteam(
        progressHandler: @escaping (InstallationState) -> Void
    ) async throws -> URL {
        // Create wrapper
        progressHandler(.settingUpWrapper(substep: nil, elapsedSeconds: nil))
        let wrapperPath = createTemporaryWrapperPath()
        print("📦 Temporary wrapper location: \(wrapperPath.path)")
        try await wrapperBuilder.createBaseWrapper(at: wrapperPath)
        
        // Install Steam client
        progressHandler(.installingGame(substep: nil, elapsedSeconds: nil))
        try await wrapperBuilder.installSteamClient(in: wrapperPath)
        
        // User installs game through Steam UI
        // This would need to launch Steam and wait for user to install
        // For now, this is a simplified version
        
        throw InstallationError.steamNotFullyImplemented
    }
    
    // MARK: - Private Helper Methods
    
    /// Install game using Wine
    private func installGameWithWine(
        wrapperPath: URL,
        gameInfo: GameInfo,
        installerPath: URL? = nil
    ) async throws -> (gameExePath: String, installerDir: String) {
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        
        // Find installer executable
        let installerExe: String
        if let installerPath = installerPath {
            // Direct installer path provided
            installerExe = installerPath.path
        } else {
            // Find setup.exe in disk directories
            let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
            
            // Check if disk-combined exists (multiple disks), otherwise use disk-1
            let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
            let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")
            
            let installerDir: URL
            if fileManager.fileExists(atPath: combinedDir.path) {
                print("Using combined disk directory for installer search")
                installerDir = combinedDir
            } else if fileManager.fileExists(atPath: disk1Dir.path) {
                print("Using disk-1 directory for installer search")
                installerDir = disk1Dir
            } else {
                print("ERROR: Could not find disk directory")
                print("  Expected at: \(disk1Dir.path)")
                print("  Or at: \(combinedDir.path)")
                throw InstallationError.diskNotFound
            }
            
            installerExe = try findInstallerExecutable(in: installerDir)
        }
        
        // Get list of exe files before installation
        let exesBefore = findExecutableFiles(in: driveCPath)
        
        // Check if debug mode is enabled to skip installer
        let skipInstaller = DebugSettings.shared.skipInstaller
        
        if skipInstaller {
            print("🐛 DEBUG: Skip installer enabled - not running installer")
            // In skip mode, we need to find a plausible game exe path
            // Use the expected path from gameInfo if available
            if let expectedPath = gameInfo.internalGameExePath {
                let expectedExePath = driveCPath.appendingPathComponent(expectedPath)
                print("🐛 DEBUG: Using expected game path: \(expectedPath)")
                
                // Create a dummy file at the expected location for testing
                let gameDir = expectedExePath.deletingLastPathComponent()
                try? fileManager.createDirectory(at: gameDir, withIntermediateDirectories: true)
                try? "".write(to: expectedExePath, atomically: true, encoding: .utf8)
                
                let relativePath = expectedExePath.path(relativeTo: driveCPath)
                
                // Determine installer directory
                let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
                let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
                let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")
                
                let installerDir: String
                if fileManager.fileExists(atPath: combinedDir.path) {
                    installerDir = "/nancy-drew-installer/disk-combined"
                } else if fileManager.fileExists(atPath: disk1Dir.path) {
                    installerDir = "/nancy-drew-installer/disk-1"
                } else {
                    installerDir = "/nancy-drew-installer"
                }
                
                return ("/" + relativePath, installerDir)
            } else {
                throw InstallationError.gameExecutableNotFound
            }
        }
        
        // Check if strict install mode is enabled (no fallback to interactive)
        let strictInstall = ProcessInfo.processInfo.environment["STRICT_INSTALL"] == "true"
        let maxAttempts = strictInstall ? 1 : 2
        
        // Try installation with automatic/silent mode first
        var installAttempt = 0
        var gameExe: URL?
        
        while gameExe == nil && installAttempt < maxAttempts {
            do {
                // Run installer
                try await runInstaller(
                    at: wrapperPath,
                    installerPath: installerExe,
                    gameInfo: gameInfo,
                    attemptNumber: installAttempt
                )
                
                // Get list of exe files after installation
                let exesAfter = findExecutableFiles(in: driveCPath)
                
                // Try to find the game executable
                do {
                    gameExe = try findGameExecutable(
                        before: exesBefore,
                        after: exesAfter,
                        expectedPath: gameInfo.internalGameExePath,
                        driveCPath: driveCPath
                    )
                } catch {
                    // Game executable not found
                    if installAttempt == 0 && !strictInstall {
                        print("⚠️ Game executable not found after silent installation, retrying with interactive mode...")
                        installAttempt += 1
                    } else {
                        // Strict mode or second attempt failed, throw the error
                        if strictInstall {
                            print("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                        }
                        throw error
                    }
                }
            } catch {
                installAttempt += 1
                if installAttempt >= maxAttempts {
                    if strictInstall {
                        print("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                    }
                    throw error
                }
                
                print("⚠️ Silent installation failed with error: \(error)")
                print("⚠️ Retrying with interactive mode...")
            }
        }
        
        // gameExe is guaranteed to be non-nil here:
        // - If nil, the loop would have continued to retry
        // - If still nil after retries, an error would have been thrown
        
        // Get relative path from drive_c
        // Use proper path manipulation to avoid issues with /private symlinks
        let relativePath = gameExe!.path(relativeTo: driveCPath)
        
        // Determine the installer directory (disk-combined or disk-1)
        let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
        let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
        let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")
        
        let installerDir: String
        if fileManager.fileExists(atPath: combinedDir.path) {
            installerDir = "/nancy-drew-installer/disk-combined"
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            installerDir = "/nancy-drew-installer/disk-1"
        } else {
            // Fallback to base directory
            installerDir = "/nancy-drew-installer"
        }
        
        return ("/" + relativePath, installerDir)
    }
    
    /// Install game using ScummVM (no actual installer needed - just returns disk path)
    private func installGameWithScummVM(
        wrapperPath: URL,
        gameInfo: GameInfo
    ) async throws -> (gameExePath: String, installerDir: String) {
        // For ScummVM games, the "installation" is simply having the disk files available
        // The disk files were already copied by wrapperBuilder.copyGameDisks()
        // We just need to return the path where the game files are located
        
        // ScummVM games don't need installation - they run directly from the disk files
        // The game files are located in SharedSupport/nancy-drew-installer/disk-1 (or disk-combined)
        
        // Check if disk-combined exists (multiple disks), otherwise use disk-1
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
        let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
        let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")
        
        let gameDir: URL
        if fileManager.fileExists(atPath: combinedDir.path) {
            print("✅ Using combined disk directory for ScummVM game")
            gameDir = combinedDir
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            print("✅ Using disk-1 directory for ScummVM game")
            gameDir = disk1Dir
        } else {
            print("ERROR: Could not find disk directory for ScummVM game")
            print("  Expected at: \(disk1Dir.path)")
            print("  Or at: \(combinedDir.path)")
            throw InstallationError.diskNotFound
        }
        
        // Return the path relative to drive_c
        // This will be used by ScummVM's --path argument
        let relativePath = gameDir.path(relativeTo: driveCPath)
        let relativeInstallerDir = gameDir.path(relativeTo: driveCPath)
        return ("/" + relativePath, "/" + relativeInstallerDir)
    }
    
    /// Run the installer with appropriate arguments based on installer type
    /// Copy AutoIt and automation script to Wine prefix for installer automation
    private func setupAutoItForInstall(in wrapperPath: URL) throws {
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        
        // Check if AutoIt is available
        guard AutoItService.shared.isAvailable else {
            throw InstallationError.autoItNotAvailable
        }
        
        // Copy AutoIt directory from bundle
        let autoitSourceDir = AutoItService.shared.autoitDir
        let autoitDestDir = driveCPath.appendingPathComponent("autoit")
        
        // Remove existing AutoIt directory if present
        if fileManager.fileExists(atPath: autoitDestDir.path) {
            try fileManager.removeItem(at: autoitDestDir)
        }
        
        // Copy AutoIt directory
        try fileManager.copyItem(at: autoitSourceDir, to: autoitDestDir)
        print("✅ Copied AutoIt to drive_c")
        
        // Copy automation script from bundle
        if let scriptPath = Bundle.main.path(forResource: "installshield-custom-dialog-automate", ofType: "au3") {
            let scriptDestPath = driveCPath.appendingPathComponent("installshield-custom-dialog-automate.au3")
            
            // Remove existing script if present
            if fileManager.fileExists(atPath: scriptDestPath.path) {
                try fileManager.removeItem(at: scriptDestPath)
            }
            
            try fileManager.copyItem(atPath: scriptPath, toPath: scriptDestPath.path)
            print("✅ Copied AutoIt script to drive_c")
        } else {
            throw InstallationError.autoItScriptNotFound
        }
    }
    
    /// Remove AutoIt files from Wine prefix after installation
    private func cleanupAutoItAfterInstall(in wrapperPath: URL) {
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let autoitDir = driveCPath.appendingPathComponent("autoit")
        let scriptPath = driveCPath.appendingPathComponent("installshield-custom-dialog-automate.au3")
        
        // Remove AutoIt directory
        if fileManager.fileExists(atPath: autoitDir.path) {
            try? fileManager.removeItem(at: autoitDir)
            print("🧹 Cleaned up AutoIt directory")
        }
        
        // Remove script
        if fileManager.fileExists(atPath: scriptPath.path) {
            try? fileManager.removeItem(at: scriptPath)
            print("🧹 Cleaned up AutoIt script")
        }
    }
    
    private func runInstaller(
        at wrapperPath: URL,
        installerPath: String,
        gameInfo: GameInfo,
        attemptNumber: Int
    ) async throws {
        let installerType = detectInstallerType(installerPath)
        print("🔧 Installer type: \(installerType)")
        
        let args = getInstallerArguments(
            installerPath: installerPath,
            installerType: installerType,
            gameInfo: gameInfo,
            wrapperPath: wrapperPath,
            attemptNumber: attemptNumber
        )
        
        // Check if we need to use AutoIt for this installer
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")
        let useAutoIt = installerType == .installShield && 
                       attemptNumber == 0 && 
                       fileManager.fileExists(atPath: setupIssPath.path) &&
                       gameInfo.doesNotExitInNonInteractiveMode
        print("Attempt number: \(attemptNumber)")
        print("Setup.iss path: \(setupIssPath.path), exists: \(fileManager.fileExists(atPath: setupIssPath.path))")
        print("Game doesNotExitInNonInteractiveMode: \(gameInfo.doesNotExitInNonInteractiveMode)")
        
        if useAutoIt {
            print("🤖 Using AutoIt automation for installer")
            
            // Setup AutoIt files in drive_c
            try setupAutoItForInstall(in: wrapperPath)
            
            // Run AutoIt with the automation script
            let autoitArgs = [
                "C:\\\\installshield-custom-dialog-automate.au3",
                installerPath,
                gameInfo.title
            ]
            
            print("🔧 Running AutoIt with args: \(autoitArgs.joined(separator: " "))")
            
            try await wineManager.runWindowsExecutable(
                at: wrapperPath,
                exePath: "C:\\\\autoit\\\\AutoIt3.exe",
                arguments: autoitArgs
            )
            
            // Cleanup AutoIt files after installation
            cleanupAutoItAfterInstall(in: wrapperPath)
        } else {
            print("🔧 Running installer with args: \(args.joined(separator: " "))")
            
            // Execute based on installer type and attempt
            if installerType == .msi {
                try await wineManager.runWindowsExecutable(
                    at: wrapperPath,
                    exePath: "msiexec",
                    arguments: args
                )
            } else {
                // For exe installers, use wine start /wait
                try await wineManager.runWindowsExecutableWithStart(
                    at: wrapperPath,
                    exePath: installerPath,
                    arguments: args
                )
            }
        }
    }
    
    /// Detect installer type from file extension and metadata
    func detectInstallerType(_ installerPath: String) -> InstallerType {
        let url = URL(fileURLWithPath: installerPath)
        
        // Check file extension first
        if url.pathExtension.lowercased() == "msi" {
            return .msi
        }
        
        // Try to extract metadata using exiftool to detect InstallShield/Inno Setup
        do {
            let metadata = try exiftool.getFileProperties(installerPath, properties: ["ProductName", "Comments"])
            print("🔍 Installer metadata: \(metadata)")
            let combined = (metadata["ProductName"] ?? "") + " " + (metadata["Comments"] ?? "")
            let lowercased = combined.lowercased()
            
            if lowercased.contains("installshield") {
                return .installShield
            } else if lowercased.contains("inno setup") {
                return .innoSetup
            }
        } catch {
            print("⚠️ Failed to detect installer type via exiftool: \(error)")
        }
        
        return .unknown
    }
    
    /// Get installer arguments based on type and attempt number
    func getInstallerArguments(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrapperPath: URL,
        attemptNumber: Int
    ) -> [String] {
        switch installerType {
        case .msi:
            if attemptNumber == 0 {
                // Silent install with logging
                return ["/qn", "/l*", "nancy-drew-install-log.txt", "/i", installerPath]
            } else {
                // Interactive install
                return ["/i", installerPath]
            }
            
        case .installShield:
            // Check for setup.iss file for silent install
            let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
            let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")
            
            if attemptNumber == 0 && fileManager.fileExists(atPath: setupIssPath.path) {
                // Use AutoIt for games that don't exit properly in non-interactive mode
                if gameInfo.doesNotExitInNonInteractiveMode {
                    // Return empty array - AutoIt will be handled specially in runInstaller
                    return []
                } else {
                    // Silent install with .iss response file
                    let windowsIssPath = "C:\\\\nancy-drew-installer\\\\setup.iss"
                    return ["/s", "/sms", "/f1\(windowsIssPath)"]
                }
            } else {
                // Interactive install with record mode
                return ["/r"]
            }
            
        case .innoSetup:
            if attemptNumber == 0 {
                // Very silent install
                return ["/verysilent", "/norestart"]
            } else {
                // Interactive install
                return []
            }
            
        case .unknown:
            // No special arguments
            return []
        }
    }
    
    /// Find installer executable in directory
    private func findInstallerExecutable(in directory: URL) throws -> String {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        
        print("Searching for installer executable in: \(directory.path)")
        
        // First look for .msi files
        for file in contents {
            if file.pathExtension.lowercased() == "msi" {
                return file.path
            }
        }
        
        // Then look for setup.exe
        for file in contents {
            let name = file.lastPathComponent.lowercased()
            if name == "setup.exe" {
                return file.path
            }
        }
        
        // Then look for install.exe
        for file in contents {
            let name = file.lastPathComponent.lowercased()
            if name == "install.exe" {
                return file.path
            }
        }
        
        // Look for any other .exe files
        let exeFiles = contents.filter { $0.pathExtension.lowercased() == "exe" }
        
        if let exe = exeFiles.first {
            return exe.path
        }
        
        print("ERROR: No installer executable found!")
        print("Expected to find .msi, setup.exe, install.exe, or any .exe file")
        print("Found \(contents.count) files/folders:")
        for file in contents {
            print("  - \(file.lastPathComponent)")
        }
        throw InstallationError.installerNotFound
    }
    
    /// Find executable files in directory
    private func findExecutableFiles(in directory: URL) -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var executables = Set<String>()
        
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "exe" {
                executables.insert(fileURL.path)
            }
        }
        
        return executables
    }
    
    /// Find the game executable after installation
    private func findGameExecutable(
        before: Set<String>,
        after: Set<String>,
        expectedPath: String?,
        driveCPath: URL
    ) throws -> URL {
        print("=== Searching for game executable ===")
        
        // Find new executables
        let newExes = after.subtracting(before)
        print("Number of executables before installation: \(before.count)")
        print("Number of executables after installation: \(after.count)")
        print("Number of new executables found: \(newExes.count)")
        
        if newExes.isEmpty {
            print("WARNING: No new executables were created during installation")
            print("First few existing executables:")
            for (index, exe) in after.prefix(5).enumerated() {
                print("  \(index + 1). \(exe)")
            }
        } else {
            print("New executables found:")
            for (index, exe) in newExes.enumerated() {
                print("  \(index + 1). \(exe)")
            }
        }
        
        // Check if expected path exists
        if let expectedPath = expectedPath {
            let fullPath = driveCPath.appendingPathComponent(expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            print("Looking for expected game executable at: \(fullPath.path)")
            if fileManager.fileExists(atPath: fullPath.path) {
                print("✓ Found game executable at expected path")
                return fullPath
            } else {
                print("✗ Expected game executable not found at: \(fullPath.path)")
            }
        } else {
            print("No expected game executable path provided in game info")
        }
        
        // Look for game.exe or similar
        print("Searching for 'game.exe' in new executables...")
        for exePath in newExes {
            let url = URL(fileURLWithPath: exePath)
            let name = url.lastPathComponent.lowercased()
            if name == "game.exe" {
                print("✓ Found game.exe at: \(exePath)")
                return url
            }
        }
        print("✗ No 'game.exe' found in new executables")
        
        // Return first new executable
        if let first = newExes.first {
            print("Using first new executable as fallback: \(first)")
            return URL(fileURLWithPath: first)
        }
        
        print("ERROR: Could not determine game executable")
        print("Search criteria:")
        print("  - Expected path: \(expectedPath ?? "none")")
        print("  - drive_c path: \(driveCPath.path)")
        print("  - New executables: \(newExes.count)")
        
        throw InstallationError.gameExecutableNotFound
    }
    
    /// Create temporary wrapper path
    private func createTemporaryWrapperPath() -> URL {
        let tempDir = fileManager.temporaryDirectory
        let wrapperName = "NancyDrew-\(UUID().uuidString).app"
        return tempDir.appendingPathComponent(wrapperName)
    }
}

// MARK: - Errors

enum InstallationError: LocalizedError {
    case unsupportedEngine
    case steamNotFullyImplemented
    case installerNotFound
    case gameExecutableNotFound
    case userCancelled
    case diskNotFound
    case autoItNotAvailable
    case autoItScriptNotFound
    
    var errorDescription: String? {
        switch self {
        case .unsupportedEngine:
            return "Unsupported game engine"
        case .steamNotFullyImplemented:
            return "Steam installation not fully implemented"
        case .installerNotFound:
            return "Could not find game installer executable"
        case .gameExecutableNotFound:
            return "Could not find game executable after installation"
        case .userCancelled:
            return "Installation cancelled by user"
        case .diskNotFound:
            return "Could not find disk-1 or disk-combined directory"
        case .autoItNotAvailable:
            return "AutoIt automation tool not available in bundle"
        case .autoItScriptNotFound:
            return "AutoIt automation script not found in bundle"
        }
    }
    
    static let cancelled = InstallationError.userCancelled
}
