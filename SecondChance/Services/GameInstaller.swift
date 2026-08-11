//
//  GameInstaller.swift
//  SecondChance
//
//  Orchestrates the complete game installation process

import Foundation
import os
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
    private let logger = Logger(subsystem: "com.secondchance", category: "GameInstaller")
    let bus: EventBus<AppEvent>

    // Track temporary wrappers for cleanup
    private var temporaryWrappers: Set<URL> = []
    private let wrappersLock = NSLock()

    init(bus: EventBus<AppEvent> = .app) {
        self.bus = bus
    }
    
    // MARK: - Main Installation Flow
    
    /// Install game from disks
    func installFromDisk(
        disk1Path: URL,
        disk2Path: URL?
    ) async throws -> URL {
        // Detect game
        logger.notice("Analyzing disk: \(disk1Path.lastPathComponent, privacy: .public)")
        let gameSlug = try await gameDetector.detectGame(fromDisk: disk1Path)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        logger.notice("Detected game: \(gameInfo.title, privacy: .public)")
        await bus.publishInstallation(.gameDetected(gameInfo))

        // Create wrapper (WrapperBuilder will report progress for setup)
        let wrapperPath = createTemporaryWrapperPath()
        registerTemporaryWrapper(wrapperPath)
        logger.notice("Temporary wrapper: \(wrapperPath.path, privacy: .public)")
        
        do {
            try await wrapperBuilder.createBaseWrapper(at: wrapperPath)

            // Copy installer
            try await wrapperBuilder.copyGameDisks(
                disk1: disk1Path,
                disk2: disk2Path,
                to: wrapperPath,
                gameSlug: gameSlug
            )

            // Install game
            Task { await self.bus.publishInstallation(.progress(.installingGame(substep: nil))) }
            let gameExePath: String
            let installerDir: String
            
            if gameInfo.gameEngine == .wine {
                await bus.publishInstallation(.engineRouted(engine: .wine, gameInfo: gameInfo))
                (gameExePath, installerDir) = try await installGameWithWine(
                    wrapperPath: wrapperPath,
                    gameInfo: gameInfo
                )
            } else if gameInfo.gameEngine == .scummvm {
                await bus.publishInstallation(.engineRouted(engine: .scummvm, gameInfo: gameInfo))
                // (gameExePath, installerDir) = try await installGameWithWine(
                //     wrapperPath: wrapperPath,
                //     gameInfo: gameInfo
                // )
                (gameExePath, installerDir) = try await installGameWithScummVM(
                    wrapperPath: wrapperPath,
                    gameInfo: gameInfo
                )
            } else {
                throw InstallationError.unsupportedEngine
            }
            
            // Clean up unused engine unless we skipped the installer since wine might be needed to run the installer later
            let skipInstaller = DebugSettings.shared.skipInstaller
            if !skipInstaller {
                try wrapperBuilder.cleanupUnusedEngine(at: wrapperPath, gameEngine: gameInfo.gameEngine)
            }
            
            // Configure wrapper
            try wrapperBuilder.configureWrapper(
                at: wrapperPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                installerDir: installerDir
            )
            await bus.publishInstallation(.wrapperConfigured(
                exePath: gameExePath,
                installerDir: installerDir,
                gameInfo: gameInfo
            ))

            return wrapperPath
        } catch {
            // Clean up on error
            cleanupTemporaryWrappers()
            throw error
        }
    }
    
    /// Install game from Her Interactive installer
    func installFromHerDownload(
        installerPath: URL
    ) async throws -> URL {
        // Detect game
        Task { await self.bus.publishInstallation(.progress(.detectingGame(substep: nil))) }
        let gameSlug = try await gameDetector.detectGame(fromInstaller: installerPath)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        logger.notice("Detected game: \(gameInfo.title, privacy: .public)")
        
        // Create wrapper (WrapperBuilder will report progress for setup)
        let wrapperPath = createTemporaryWrapperPath()
        registerTemporaryWrapper(wrapperPath)
        logger.notice("Temporary wrapper: \(wrapperPath.path, privacy: .public)")

        do {
            try await wrapperBuilder.createBaseWrapper(at: wrapperPath)

            // Install game
            Task { await self.bus.publishInstallation(.progress(.installingGame(substep: nil))) }
            let (gameExePath, installerDir) = try await installGameWithWine(
                wrapperPath: wrapperPath,
                gameInfo: gameInfo,
                installerPath: installerPath
            )

            // Clean up unused engine
            try wrapperBuilder.cleanupUnusedEngine(at: wrapperPath, gameEngine: gameInfo.gameEngine)

            // Configure wrapper
            try wrapperBuilder.configureWrapper(
                at: wrapperPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                installerDir: installerDir
            )
            
            return wrapperPath
        } catch {
            // Clean up on error
            cleanupTemporaryWrappers()
            throw error
        }
    }
    
    /// Install game from Steam
    func installFromSteam() async throws -> URL {
        let wrapperPath = createTemporaryWrapperPath()
        registerTemporaryWrapper(wrapperPath)
        logger.notice("Temporary wrapper: \(wrapperPath.path, privacy: .public)")
        try await wrapperBuilder.createBaseWrapper(at: wrapperPath)
        Task { await self.bus.publishInstallation(.progress(.installingGame(substep: nil))) }
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
                logger.notice("Using combined disk directory for installer search")
                installerDir = combinedDir
            } else if fileManager.fileExists(atPath: disk1Dir.path) {
                logger.notice("Using disk-1 directory for installer search")
                installerDir = disk1Dir
            } else {
                logger.fault("Could not find disk directory — expected at \(disk1Dir.path, privacy: .public) or \(combinedDir.path, privacy: .public)")
                throw InstallationError.diskNotFound
            }
            
            installerExe = try findInstallerExecutable(in: installerDir)
        }
        
        // Get list of exe files before installation
        let exesBefore = findExecutableFiles(in: driveCPath)
        
        // Check if debug mode is enabled to skip installer
        let skipInstaller = DebugSettings.shared.skipInstaller
        
        if skipInstaller {
            logger.notice("DEBUG: Skip installer enabled — using installer path as game exe: \(installerExe, privacy: .public)")
            
            // Show what command would have been run using the same code path
            let installerType = detectInstallerType(installerExe)
            let command = buildInstallerCommand(
                installerPath: installerExe,
                installerType: installerType,
                gameInfo: gameInfo,
                wrapperPath: wrapperPath,
                attemptNumber: 0
            )
            logger.notice("DEBUG: Would have run: \(command.commandDescription, privacy: .public)")
            if let underlyingCommand = command.underlyingCommandDescription {
                logger.notice("DEBUG:    Automating: \(underlyingCommand, privacy: .public)")
            }
            
            // Use the installer executable path as the game executable
            // This allows testing the wrapper without actually installing
            let installerURL = URL(fileURLWithPath: installerExe)
            let relativePath = installerURL.path(relativeTo: driveCPath)
            
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
            
            await bus.publishInstallation(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))
            return ("/" + relativePath, installerDir)
        }

        // Check if strict install mode is enabled (no fallback to interactive)
        let strictInstall = ProcessInfo.processInfo.environment["STRICT_INSTALL"] == "true"
        let maxAttempts = strictInstall ? 1 : 2
        
        // Try installation with automatic/silent mode first
        var installAttempt = 0
        var gameExe: URL?
        
        while gameExe == nil && installAttempt < maxAttempts {
            logger.notice("🔄 Installation attempt \(installAttempt + 1, privacy: .public) of \(maxAttempts, privacy: .public)")
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
                        logger.error("Game exe not found after silent install — retrying with interactive mode...")
                        installAttempt += 1
                    } else {
                        // Strict mode or second attempt failed, throw the error
                        if strictInstall {
                            logger.fault("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                        }
                        throw error
                    }
                }
            } catch {
                installAttempt += 1
                if installAttempt >= maxAttempts {
                    if strictInstall {
                        logger.fault("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                    } else {
                        logger.fault("❌ Installation failed after \(installAttempt, privacy: .public) attempts")
                    }
                    throw error
                }
                
                logger.error("Silent install failed: \(error, privacy: .public) — retrying with interactive mode...")
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
        
        await bus.publishInstallation(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))
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
            logger.notice("✅ Using combined disk directory for ScummVM game")
            gameDir = combinedDir
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            logger.notice("✅ Using disk-1 directory for ScummVM game")
            gameDir = disk1Dir
        } else {
            logger.fault("Could not find disk directory for ScummVM game — expected at \(disk1Dir.path, privacy: .public) or \(combinedDir.path, privacy: .public)")
            throw InstallationError.diskNotFound
        }
        
        // Return the path relative to drive_c
        // This will be used by ScummVM's --path argument
        let relativePath = gameDir.path(relativeTo: driveCPath)
        let relativeInstallerDir = gameDir.path(relativeTo: driveCPath)
        await bus.publishInstallation(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))
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
        logger.notice("✅ Copied AutoIt to drive_c")
        
        // Copy automation script from bundle
        if let scriptPath = Bundle.main.path(forResource: "installshield-custom-dialog-automate", ofType: "au3") {
            let scriptDestPath = driveCPath.appendingPathComponent("installshield-custom-dialog-automate.au3")
            
            // Remove existing script if present
            if fileManager.fileExists(atPath: scriptDestPath.path) {
                try fileManager.removeItem(at: scriptDestPath)
            }
            
            try fileManager.copyItem(atPath: scriptPath, toPath: scriptDestPath.path)
            logger.notice("✅ Copied AutoIt script to drive_c")
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
            logger.notice("🧹 Cleaned up AutoIt directory")
        }
        
        // Remove script
        if fileManager.fileExists(atPath: scriptPath.path) {
            try? fileManager.removeItem(at: scriptPath)
            logger.notice("🧹 Cleaned up AutoIt script")
        }
    }
    
    /// Information about how to execute an installer
    private struct InstallerCommand {
        let exePath: String
        let arguments: [String]
        let useStartCommand: Bool
        let commandDescription: String
        let underlyingCommandDescription: String?
    }
    
    /// Build the installer command that should be executed
    private func buildInstallerCommand(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrapperPath: URL,
        attemptNumber: Int
    ) -> InstallerCommand {
        // Get installer arguments
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
        
        if useAutoIt {
            let autoitArgs = [
                "C:\\\\installshield-custom-dialog-automate.au3",
                installerPath,
                gameInfo.title
            ]
            let underlyingCommand = installerType == .msi 
                ? "msiexec \(args.joined(separator: " "))"
                : "wine start /wait \(installerPath) \(args.joined(separator: " "))"
            
            return InstallerCommand(
                exePath: "C:\\\\autoit\\\\AutoIt3.exe",
                arguments: autoitArgs,
                useStartCommand: false,
                commandDescription: "C:\\\\autoit\\\\AutoIt3.exe \(autoitArgs.joined(separator: " "))",
                underlyingCommandDescription: underlyingCommand
            )
        } else if installerType == .msi {
            return InstallerCommand(
                exePath: "msiexec",
                arguments: args,
                useStartCommand: false,
                commandDescription: "msiexec \(args.joined(separator: " "))",
                underlyingCommandDescription: nil
            )
        } else {
            return InstallerCommand(
                exePath: installerPath,
                arguments: args,
                useStartCommand: true,
                commandDescription: "wine start /wait \(installerPath) \(args.joined(separator: " "))",
                underlyingCommandDescription: nil
            )
        }
    }
    
    private func runInstaller(
        at wrapperPath: URL,
        installerPath: String,
        gameInfo: GameInfo,
        attemptNumber: Int
    ) async throws {
        let installerType = detectInstallerType(installerPath)
        let installerTypeDesc = String(describing: installerType)
        logger.notice("Installer type: \(installerTypeDesc, privacy: .public)")
        await bus.publishInstallation(.installerResolved(exePath: installerPath, type: installerType))

        // Check if we need to use AutoIt for this installer
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")
        let useAutoIt = installerType == .installShield && 
                       attemptNumber == 0 && 
                       fileManager.fileExists(atPath: setupIssPath.path) &&
                       gameInfo.doesNotExitInNonInteractiveMode
        logger.notice("Attempt number: \(attemptNumber, privacy: .public)")
        let setupIssExists = fileManager.fileExists(atPath: setupIssPath.path)
        logger.notice("Setup.iss path: \(setupIssPath.path, privacy: .public), exists: \(setupIssExists, privacy: .public)")
        logger.notice("Game doesNotExitInNonInteractiveMode: \(gameInfo.doesNotExitInNonInteractiveMode, privacy: .public)")
        
        // Build and print the command that will be executed
        let command = buildInstallerCommand(
            installerPath: installerPath,
            installerType: installerType,
            gameInfo: gameInfo,
            wrapperPath: wrapperPath,
            attemptNumber: attemptNumber
        )
        logger.notice("Running: \(command.commandDescription, privacy: .public)")
        if let underlyingCommand = command.underlyingCommandDescription {
            logger.notice("   Automating: \(underlyingCommand, privacy: .public)")
        }
        
        // Setup AutoIt if needed
        if command.underlyingCommandDescription != nil {
            try setupAutoItForInstall(in: wrapperPath)
        }
        
        // Execute the installer command. The WineManager methods return the
        // Wine exit code (and log a warning if non-zero) rather than throwing
        // for non-zero exits.
        let exitCode: Int32
        if command.useStartCommand {
            exitCode = try await wineManager.runWindowsExecutableWithStart(
                at: wrapperPath,
                exePath: command.exePath,
                arguments: command.arguments
            )
        } else {
            exitCode = try await wineManager.runWindowsExecutable(
                at: wrapperPath,
                exePath: command.exePath,
                arguments: command.arguments
            )
        }
        
        // A non-zero exit code usually means the install failed. Throw so the
        // caller's silent→interactive retry logic can kick in (WineManager has
        // already logged the warning with the exit code).
        if exitCode != 0 {
            throw WineError.executionFailed(exitCode: exitCode)
        }
        
        // Cleanup AutoIt if it was used (skip in debug mode to allow manual re-runs)
        if command.underlyingCommandDescription != nil {
            if DebugSettings.shared.debugMode {
                logger.notice("DEBUG: Keeping AutoIt files for manual re-run")
            } else {
                cleanupAutoItAfterInstall(in: wrapperPath)
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
            logger.notice("🔍 Installer metadata: \(metadata, privacy: .public)")
            let combined = (metadata["ProductName"] ?? "") + " " + (metadata["Comments"] ?? "")
            let lowercased = combined.lowercased()
            
            if lowercased.contains("installshield") {
                return .installShield
            } else if lowercased.contains("inno setup") {
                return .innoSetup
            }
        } catch {
            logger.error("⚠️ Failed to detect installer type via exiftool: \(error, privacy: .public)")
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
        
        logger.notice("Searching for installer executable in: \(directory.path, privacy: .public)")
        
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
        
        logger.fault("ERROR: No installer executable found!")
        logger.notice("Expected to find .msi, setup.exe, install.exe, or any .exe file")
        logger.notice("Found \(contents.count, privacy: .public) files/folders:")
        for file in contents {
            logger.notice("  - \(file.lastPathComponent, privacy: .public)")
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
        logger.notice("=== Searching for game executable ===")
        
        // Find new executables
        let newExes = after.subtracting(before)
        logger.notice("Number of executables before installation: \(before.count, privacy: .public)")
        logger.notice("Number of executables after installation: \(after.count, privacy: .public)")
        logger.notice("Number of new executables found: \(newExes.count, privacy: .public)")
        
        if newExes.isEmpty {
            logger.error("WARNING: No new executables were created during installation")
            logger.notice("First few existing executables:")
            for (index, exe) in after.prefix(5).enumerated() {
                logger.notice("  \(index + 1, privacy: .public). \(exe, privacy: .public)")
            }
        } else {
            logger.notice("New executables found:")
            for (index, exe) in newExes.enumerated() {
                logger.notice("  \(index + 1, privacy: .public). \(exe, privacy: .public)")
            }
        }
        
        // Check if expected path exists
        if let expectedPath = expectedPath {
            let fullPath = driveCPath.appendingPathComponent(expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            logger.notice("Looking for expected game executable at: \(fullPath.path, privacy: .public)")
            if fileManager.fileExists(atPath: fullPath.path) {
                logger.notice("✓ Found game executable at expected path")
                return fullPath
            } else {
                logger.notice("✗ Expected game executable not found at: \(fullPath.path, privacy: .public)")
            }
        } else {
            logger.notice("No expected game executable path provided in game info")
        }
        
        // Look for game.exe or similar
        logger.notice("Searching for 'game.exe' in new executables...")
        for exePath in newExes {
            let url = URL(fileURLWithPath: exePath)
            let name = url.lastPathComponent.lowercased()
            if name == "game.exe" {
                logger.notice("✓ Found game.exe at: \(exePath, privacy: .public)")
                return url
            }
        }
        logger.notice("✗ No 'game.exe' found in new executables")
        
        // Return first new executable
        if let first = newExes.first {
            logger.notice("Using first new executable as fallback: \(first, privacy: .public)")
            return URL(fileURLWithPath: first)
        }
        
        logger.fault("ERROR: Could not determine game executable")
        logger.notice("Search criteria:")
        logger.notice("  - Expected path: \(expectedPath ?? "none", privacy: .public)")
        logger.notice("  - drive_c path: \(driveCPath.path, privacy: .public)")
        logger.notice("  - New executables: \(newExes.count, privacy: .public)")
        
        throw InstallationError.gameExecutableNotFound
    }
    
    /// Create temporary wrapper path
    private func createTemporaryWrapperPath() -> URL {
        let tempDir = fileManager.temporaryDirectory
        let wrapperName = "NancyDrew-\(UUID().uuidString).app"
        return tempDir.appendingPathComponent(wrapperName)
    }
    
    /// Register a temporary wrapper for tracking
    private func registerTemporaryWrapper(_ path: URL) {
        wrappersLock.lock()
        defer { wrappersLock.unlock() }
        temporaryWrappers.insert(path)
    }
    
    /// Unregister a temporary wrapper (call after successful move/save)
    func unregisterTemporaryWrapper(_ path: URL) {
        wrappersLock.lock()
        defer { wrappersLock.unlock() }
        temporaryWrappers.remove(path)
    }
    
    /// Clean up all tracked temporary wrappers
    func cleanupTemporaryWrappers() {
        wrappersLock.lock()
        let wrappers = Array(temporaryWrappers)
        temporaryWrappers.removeAll()
        wrappersLock.unlock()
        
        guard !wrappers.isEmpty else { return }
        
        // Skip deletion in debug mode
        if DebugSettings.shared.debugMode {
            logger.notice("🐛 DEBUG: Keeping \(wrappers.count, privacy: .public) temporary wrapper(s) for inspection:")
            for wrapper in wrappers {
                if fileManager.fileExists(atPath: wrapper.path) {
                    logger.notice("   \(wrapper.path, privacy: .public)")
                }
            }
            return
        }
        
        logger.notice("🧹 Cleaning up \(wrappers.count, privacy: .public) temporary wrapper(s)...")
        for wrapper in wrappers {
            do {
                if fileManager.fileExists(atPath: wrapper.path) {
                    logger.notice("   Removing: \(wrapper.path, privacy: .public)")
                    try fileManager.removeItem(at: wrapper)
                }
            } catch {
                logger.error("   ⚠️ Failed to remove \(wrapper.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Errors

enum InstallationError: LocalizedError, Equatable {
    case unsupportedEngine
    case steamNotFullyImplemented
    case installerNotFound
    case gameExecutableNotFound
    case userCancelled
    case diskNotFound
    case autoItNotAvailable
    case autoItScriptNotFound
    case missingRequiredParameter(String)
    case invalidPath(String)
    case internalError(String)
    
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
        case .missingRequiredParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidPath(let message):
            return "Invalid path: \(message)"
        case .internalError(let message):
            return message
        }
    }
    
    static let cancelled = InstallationError.userCancelled
}
