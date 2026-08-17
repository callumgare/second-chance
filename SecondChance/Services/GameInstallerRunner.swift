//
//  GameInstallerRunner.swift
//  SecondChance
//
//  Runs a Windows game installer inside a wrapp and locates the resulting
//  game executable. Owns the installer-execution machinery: command
//  building, AutoIt automation, MSI log streaming, the silent→interactive
//  retry loop, before/after exe diffing, and post-install game patches.
//  Extracted from GameInstaller.
//

import Foundation
import Logging

/// Runs the game's own installer (setup.exe / .msi) inside the Wine prefix
/// and finds what it installed.
///
/// Build-aware: knows about installer types (MSI, InstallShield, Inno Setup),
/// silent/interactive strategies, and AutoIt automation. Delegates actual
/// execution to WineManager.
class GameInstallerRunner {
    static let shared = GameInstallerRunner()

    /// Ask the user whether to continue after a patch failed.
    ///
    /// Confirmation is injected via `patchFailureConfirmation` (default:
    /// continue without prompting). The GUI supplies an NSAlert-based
    /// handler through `WrappBuildInput.confirmPatchFailure`; headless runs
    /// default to continuing (a modal alert under a `.prohibited` activation
    /// policy is invisible and would hang the build forever).
    var patchFailureConfirmation: (@MainActor (String, Error) async -> Bool)?

    private let fileManager = FileManager.default
    private let wineManager: WineManager
    private let exiftool: ExiftoolService
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner")
    let bus: EventBus<AppEvent>

    init(
        wineManager: WineManager = .shared,
        exiftool: ExiftoolService = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.wineManager = wineManager
        self.exiftool = exiftool
        self.bus = bus
    }

    // MARK: - Game Installation

    /// Install game using Wine
    func installGameWithWine(
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
            let installerDir = try findInstallerDirectory(in: driveCPath)
            installerExe = try findInstallerExecutable(in: installerDir)
        }

        // Get list of exe files before installation
        let exesBefore = findExecutableFiles(in: driveCPath)

        // Check if debug mode is enabled to skip installer
        let skipInstaller = DebugSettings.shared.skipInstaller

        if skipInstaller {
            logger.notice("DEBUG: Skip installer enabled — using installer path as game exe: \(installerExe)")

            // Show what command would have been run using the same code path
            let installerType = detectInstallerType(installerExe)
            let command = buildInstallerCommand(
                installerPath: installerExe,
                installerType: installerType,
                gameInfo: gameInfo,
                wrapperPath: wrapperPath,
                attemptNumber: 0
            )
            logger.notice("DEBUG: Would have run: \(command.commandDescription)")
            if let underlyingCommand = command.underlyingCommandDescription {
                logger.notice("DEBUG:    Automating: \(underlyingCommand)")
            }

            // Use the installer executable path as the game executable
            // This allows testing the wrapper without actually installing
            let installerURL = URL(fileURLWithPath: installerExe)
            let relativePath = installerURL.path(relativeTo: driveCPath)
            let installerDir = installerDirectoryPath(in: driveCPath)

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
            logger.notice("🔄 Installation attempt \(installAttempt + 1) of \(maxAttempts)")
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
                            logger.critical("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                        }
                        throw error
                    }
                }
            } catch {
                installAttempt += 1
                if installAttempt >= maxAttempts {
                    if strictInstall {
                        logger.critical("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                    } else {
                        logger.critical("❌ Installation failed after \(installAttempt) attempts")
                    }
                    throw error
                }

                logger.error("Silent install failed: \(error) — retrying with interactive mode...")
            }
        }

        // gameExe is guaranteed to be non-nil here:
        // - If nil, the loop would have continued to retry
        // - If still nil after retries, an error would have been thrown

        // Get relative path from drive_c
        // Use proper path manipulation to avoid issues with /private symlinks
        let relativePath = gameExe!.path(relativeTo: driveCPath)

        // Determine the installer directory (disk-combined or disk-1)
        let installerDir = installerDirectoryPath(in: driveCPath)

        await bus.publishInstallation(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))

        // Apply any available game patches
        do {
            try await applyGamePatches(
                wrapperPath: wrapperPath,
                gameInfo: gameInfo,
                gameExePath: "/" + relativePath
            )
        } catch InstallationError.userCancelled {
            throw InstallationError.userCancelled
        } catch {
            logger.error("⚠️  Failed to apply patches: \(error)")
        }

        return ("/" + relativePath, installerDir)
    }

    /// Install game using ScummVM (no actual installer needed - just returns disk path)
    func installGameWithScummVM(
        wrapperPath: URL,
        gameInfo: GameInfo
    ) async throws -> (gameExePath: String, installerDir: String) {
        // For ScummVM games, the "installation" is simply having the disk files available
        // The disk files were already copied by wrapperBuilder.copyGameDisks()
        // We just need to return the path where the game files are located

        // ScummVM games don't need installation - they run directly from the disk files
        // The game files are located in SharedSupport/nancy-drew-installer/disk-1 (or disk-combined)

        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let gameDir = try findInstallerDirectory(in: driveCPath)

        // Return the path relative to drive_c
        // This will be used by ScummVM's --path argument
        let relativePath = gameDir.path(relativeTo: driveCPath)
        let relativeInstallerDir = gameDir.path(relativeTo: driveCPath)
        await bus.publishInstallation(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))
        return ("/" + relativePath, "/" + relativeInstallerDir)
    }

    // MARK: - Disk Directory Resolution

    /// Find the directory containing the installer: prefer disk-combined, else
    /// disk-1, else fail. Centralizes a lookup that was previously duplicated.
    private func findInstallerDirectory(in driveCPath: URL) throws -> URL {
        let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
        let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
        let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")

        if fileManager.fileExists(atPath: combinedDir.path) {
            logger.notice("Using combined disk directory")
            return combinedDir
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            logger.notice("Using disk-1 directory")
            return disk1Dir
        } else {
            logger.critical("Could not find disk directory — expected at \(disk1Dir.path) or \(combinedDir.path)")
            throw InstallationError.diskNotFound
        }
    }

    /// The installer directory as a Windows-style path relative to drive_c
    /// (e.g. "/nancy-drew-installer/disk-1").
    private func installerDirectoryPath(in driveCPath: URL) -> String {
        let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
        let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
        let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")

        if fileManager.fileExists(atPath: combinedDir.path) {
            return "/nancy-drew-installer/disk-combined"
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            return "/nancy-drew-installer/disk-1"
        } else {
            return "/nancy-drew-installer"
        }
    }

    // MARK: - Game Patches

    /// Apply game patches if available
    private func applyGamePatches(
        wrapperPath: URL,
        gameInfo: GameInfo,
        gameExePath: String
    ) async throws {
        let gameSlug = gameInfo.id
        guard let patchesCacheDir = Bundle.main.url(forResource: gameSlug, withExtension: nil, subdirectory: "game-patches") else {
            logger.notice("ℹ️  No patches found for game '\(gameSlug)'")
            return
        }

        // Get list of patch files
        let patchFiles = try fileManager.contentsOfDirectory(at: patchesCacheDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }

        guard !patchFiles.isEmpty else {
            logger.notice("ℹ️  No zip patch files found for game '\(gameSlug)'")
            return
        }

        logger.notice("🔧 Applying patches for game '\(gameSlug)'...")

        // Get the game installation directory
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let gameExeFullPath = driveCPath.appendingPathComponent(String(gameExePath.dropFirst()))
        let gameInstallDir = gameExeFullPath.deletingLastPathComponent()

        // Process each patch file
        for patchFile in patchFiles {
            logger.notice("📦 Processing patch: \(patchFile.lastPathComponent)")

            // Unzip the patch to a temporary directory
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("patch-\(UUID().uuidString)")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

            defer {
                try? fileManager.removeItem(at: tempDir)
            }

            // Use unzip command to extract the patch
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-q", patchFile.path, "-d", tempDir.path]

            try unzipProcess.run()
            unzipProcess.waitUntilExit()

            guard unzipProcess.terminationStatus == 0 else {
                logger.error("❌ Failed to unzip patch: \(patchFile.lastPathComponent)")
                continue
            }

            // Look for patch exe files in the unzipped content
            let unzippedFiles = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "exe" }

            guard !unzippedFiles.isEmpty else {
                logger.notice("⚠️  No exe files found in patch: \(patchFile.lastPathComponent)")
                continue
            }

            // Copy unzipped files to game installation directory
            for unzippedFile in unzippedFiles {
                let destPath = gameInstallDir.appendingPathComponent(unzippedFile.lastPathComponent)
                try fileManager.copyItem(at: unzippedFile, to: destPath)
                logger.notice("✓ Copied \(unzippedFile.lastPathComponent) to game directory")
            }
        }

        // Run patch exes found in game directory
        let patchExes = try fileManager.contentsOfDirectory(at: gameInstallDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("patch") && $0.pathExtension == "exe" }

        for patchExe in patchExes {
            let winePath = String(patchExe.path.dropFirst(driveCPath.path.count))
            logger.notice("🚀 Running patch: \(patchExe.lastPathComponent)")

            do {
                _ = try await wineManager.runWindowsExecutable(
                    at: wrapperPath,
                    exePath: winePath,
                    arguments: []
                )
                logger.notice("✅ Patch completed: \(patchExe.lastPathComponent)")
            } catch {
                logger.error("❌ Patch failed: \(patchExe.lastPathComponent): \(error)")
                let continueInstall = await confirmPatchFailure(patchName: patchExe.lastPathComponent, error: error)
                if continueInstall {
                    logger.notice("⚠️  Continuing installation without patch: \(patchExe.lastPathComponent)")
                } else {
                    throw InstallationError.userCancelled
                }
            }
        }

        logger.notice("✅ All patches applied successfully")
    }

    /// Route a patch-failure confirmation through the injected handler when
    /// present, otherwise continue without prompting (headless default —
    /// a modal alert under a `.prohibited` activation policy would be
    /// invisible and hang the build forever).
    @MainActor
    private func confirmPatchFailure(patchName: String, error: Error) async -> Bool {
        if let confirmation = patchFailureConfirmation {
            return await confirmation(patchName, error)
        }
        logger.notice("No patch-failure handler installed — continuing without patch '\(patchName)'")
        return true
    }

    // MARK: - AutoIt Automation

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

    // MARK: - Installer Command Building

    /// Information about how to execute an installer
    private struct InstallerCommand {
        let exePath: String
        let arguments: [String]
        let useStartCommand: Bool
        let commandDescription: String
        /// Non-nil when AutoIt automates an underlying installer command.
        /// This is the single source of truth for "is AutoIt being used".
        let underlyingCommandDescription: String?
    }

    /// Host and Windows paths for an MSI log file.
    private struct MsiLogDestination {
        let hostPath: URL
        let windowsPath: String
    }

    /// Build a unique MSI log file path in the Wine prefix temp directory.
    private func prepareMsiLogDestination(in wrapperPath: URL) throws -> MsiLogDestination {
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let windowsTempDir = driveCPath.appendingPathComponent("windows/temp")
        try fileManager.createDirectory(at: windowsTempDir, withIntermediateDirectories: true)

        let fileName = "nancy-drew-install-\(UUID().uuidString).log"
        let hostPath = windowsTempDir.appendingPathComponent(fileName)
        fileManager.createFile(atPath: hostPath.path, contents: nil)

        return MsiLogDestination(
            hostPath: hostPath,
            windowsPath: "C:\\\\windows\\\\temp\\\\\(fileName)"
        )
    }

    /// Stream an MSI log file line-by-line to a dedicated logger.
    private func startMsiLogStreaming(at logPath: URL) throws -> TaggedProcess {
        let msiLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner.msi-log")
        let process = TaggedProcess(logger: msiLogger)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "+1", "-F", logPath.path]
        try process.run()
        return process
    }

    /// Build the installer command that should be executed
    private func buildInstallerCommand(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrapperPath: URL,
        attemptNumber: Int,
        msiLogPath: String? = nil
    ) -> InstallerCommand {
        // Get installer arguments
        let args = getInstallerArguments(
            installerPath: installerPath,
            installerType: installerType,
            gameInfo: gameInfo,
            wrapperPath: wrapperPath,
            attemptNumber: attemptNumber,
            msiLogPath: msiLogPath
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

    // MARK: - Installer Execution

    /// Run the installer with appropriate arguments based on installer type
    private func runInstaller(
        at wrapperPath: URL,
        installerPath: String,
        gameInfo: GameInfo,
        attemptNumber: Int
    ) async throws {
        let installerType = detectInstallerType(installerPath)
        let installerTypeDesc = String(describing: installerType)
        logger.notice("Installer type: \(installerTypeDesc)")
        await bus.publishInstallation(.installerResolved(exePath: installerPath, type: installerType))

        // Diagnostic logging for the AutoIt decision (the decision itself is
        // made once, inside buildInstallerCommand).
        logger.notice("Attempt number: \(attemptNumber)")
        let driveCPath = wrapperPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")
        let setupIssExists = fileManager.fileExists(atPath: setupIssPath.path)
        logger.notice("Setup.iss path: \(setupIssPath.path), exists: \(setupIssExists)")
        logger.notice("Game doesNotExitInNonInteractiveMode: \(gameInfo.doesNotExitInNonInteractiveMode)")

        let msiLogDestination = installerType == .msi
            ? try prepareMsiLogDestination(in: wrapperPath)
            : nil
        if let msiLogDestination {
            logger.notice("MSI install log file: \(msiLogDestination.hostPath.path)")
        }

        // Build and print the command that will be executed
        let command = buildInstallerCommand(
            installerPath: installerPath,
            installerType: installerType,
            gameInfo: gameInfo,
            wrapperPath: wrapperPath,
            attemptNumber: attemptNumber,
            msiLogPath: msiLogDestination?.windowsPath
        )
        logger.notice("Running: \(command.commandDescription)")
        if let underlyingCommand = command.underlyingCommandDescription {
            logger.notice("   Automating: \(underlyingCommand)")
        }

        // Stream MSI log lines independently from Wine stdout/stderr.
        var msiLogStreamer: TaggedProcess?
        if let msiLogDestination {
            msiLogStreamer = try startMsiLogStreaming(at: msiLogDestination.hostPath)
        }
        defer {
            if let msiLogStreamer {
                msiLogStreamer.terminate()
                msiLogStreamer.waitUntilExit()
            }
            if let msiLogDestination, !DebugSettings.shared.debugMode {
                try? fileManager.removeItem(at: msiLogDestination.hostPath)
            }
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

    // MARK: - Installer Type Detection

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
            logger.notice("🔍 Installer metadata: \(metadata)")
            let combined = (metadata["ProductName"] ?? "") + " " + (metadata["Comments"] ?? "")
            let lowercased = combined.lowercased()

            if lowercased.contains("installshield") {
                return .installShield
            } else if lowercased.contains("inno setup") {
                return .innoSetup
            }
        } catch {
            logger.error("⚠️ Failed to detect installer type via exiftool: \(error)")
        }

        return .unknown
    }

    /// Get installer arguments based on type and attempt number
    func getInstallerArguments(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrapperPath: URL,
        attemptNumber: Int,
        msiLogPath: String? = nil
    ) -> [String] {
        switch installerType {
        case .msi:
            let logPath = msiLogPath ?? "nancy-drew-install-log.txt"
            if attemptNumber == 0 {
                // Silent install with logging
                return ["/qn", "/l*", logPath, "/i", installerPath]
            } else {
                // Interactive install (still collect installer logs)
                return ["/l*", logPath, "/i", installerPath]
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

    // MARK: - Executable Discovery

    /// Find installer executable in directory
    private func findInstallerExecutable(in directory: URL) throws -> String {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )

        logger.notice("Searching for installer executable in: \(directory.path)")

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

        logger.critical("ERROR: No installer executable found!")
        logger.notice("Expected to find .msi, setup.exe, install.exe, or any .exe file")
        logger.notice("Found \(contents.count) files/folders:")
        for file in contents {
            logger.notice("  - \(file.lastPathComponent)")
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
        logger.notice("Number of executables before installation: \(before.count)")
        logger.notice("Number of executables after installation: \(after.count)")
        logger.notice("Number of new executables found: \(newExes.count)")

        if newExes.isEmpty {
            logger.error("WARNING: No new executables were created during installation")
            logger.notice("First few existing executables:")
            for (index, exe) in after.prefix(5).enumerated() {
                logger.notice("  \(index + 1). \(exe)")
            }
        } else {
            logger.notice("New executables found:")
            for (index, exe) in newExes.enumerated() {
                logger.notice("  \(index + 1). \(exe)")
            }
        }

        // Check if expected path exists
        if let expectedPath = expectedPath {
            let fullPath = driveCPath.appendingPathComponent(expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            logger.notice("Looking for expected game executable at: \(fullPath.path)")
            if fileManager.fileExists(atPath: fullPath.path) {
                logger.notice("✓ Found game executable at expected path")
                return fullPath
            } else {
                logger.notice("✗ Expected game executable not found at: \(fullPath.path)")
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
                logger.notice("✓ Found game.exe at: \(exePath)")
                return url
            }
        }
        logger.notice("✗ No 'game.exe' found in new executables")

        // Return first new executable
        if let first = newExes.first {
            logger.notice("Using first new executable as fallback: \(first)")
            return URL(fileURLWithPath: first)
        }

        logger.critical("ERROR: Could not determine game executable")
        logger.notice("Search criteria:")
        logger.notice("  - Expected path: \(expectedPath ?? "none")")
        logger.notice("  - drive_c path: \(driveCPath.path)")
        logger.notice("  - New executables: \(newExes.count)")

        throw InstallationError.gameExecutableNotFound
    }
}
