//
//  InstallationService.swift
//  SecondChance
//
//  Service for managing game installation without UI concerns

import Foundation
import os
import AppKit

/// Thread-safe tracker for mounted ISOs
actor MountedISOTracker {
    private var mountedISOs: Set<URL> = []
    
    func insert(_ url: URL) {
        mountedISOs.insert(url)
    }
    
    func getAll() -> Set<URL> {
        return mountedISOs
    }
    
    func removeAll() {
        mountedISOs.removeAll()
    }
}

/// Service for handling game installation logic without UI dependencies
/// Not tied to any actor, can be called from any context
class InstallationService {
    private let gameInstaller: GameInstaller
    private let mountedISOTracker = MountedISOTracker()
    let bus: EventBus<AppEvent>
    private let logger = Logger(subsystem: "com.secondchance", category: "InstallationService")

    init(bus: EventBus<AppEvent> = .app) {
        self.bus = bus
        self.gameInstaller = GameInstaller(bus: bus)
    }
    
    // MARK: - Unified Installation Flow
    
    /// Complete installation coordinator with guaranteed cleanup
    /// This is the unified entry point used by both interactive and non-interactive modes
    func performInstallation(
        context: InstallationContext
    ) async throws -> URL {
        // Top-level error handling with guaranteed cleanup
        do {
            // Signal start
            await bus.publishInstallation(.started(source: .disk))

            // Get input paths
            let disk1 = try await context.getDisk1Path()
            logger.notice("Disk 1: \(disk1.path, privacy: .public)")

            // Mount disk 1 if ISO
            let disk1Mounted: URL
            if disk1.pathExtension.lowercased() == "iso" {
                disk1Mounted = try await mountISO(at: disk1, context: context)
                await bus.publishInstallation(.isoMounted(disk1Mounted))
            } else {
                disk1Mounted = disk1
            }
            
            // Detect game
            await bus.publishInstallation(.progress(.detectingGame(substep: nil)))
            let gameSlug = try await GameDetector.shared.detectGame(fromDisk: disk1Mounted)
            let gameInfo = GameInfoProvider.shared.gameInfo(for: gameSlug)
            await context.onGameDetected(gameInfo)
            
            // Get disk 2 if needed
            var disk2Mounted: URL?
            if gameInfo.diskCount > 1 {
                if let disk2 = try await context.getDisk2Path(gameInfo: gameInfo) {
                    logger.notice("Disk 2: \(disk2.path, privacy: .public)")
                    if disk2.pathExtension.lowercased() == "iso" {
                        disk2Mounted = try await mountISO(at: disk2, context: context)
                        await bus.publishInstallation(.isoMounted(disk2Mounted!))
                    } else {
                        disk2Mounted = disk2
                    }
                }
            }

            // Signal that disk resolution is complete
            await bus.publishInstallation(.disksResolved(disk1: disk1Mounted, disk2: disk2Mounted))
            
            // Install game
            let wrapperPath = try await gameInstaller.installFromDisk(
                disk1Path: disk1Mounted,
                disk2Path: disk2Mounted
            )
            
            // Sign wrapper before moving (so failures trigger cleanup)
            try WrapperBuilder.shared.signWrapper(at: wrapperPath)
            await bus.publishInstallation(.signed(wrapperPath: wrapperPath))
            
            // Save wrapper
            let outputDir = try await context.getOutputPath(gameName: gameInfo.title)
            let finalPath = try await saveWrapper(
                from: wrapperPath,
                to: outputDir,
                gameName: gameInfo.title
            )
            
            // Unmount ISOs now that installation is complete
            await unmountAllISOs()
            
            await context.onInstallationComplete(finalPath)
            await bus.publishInstallation(.completed(wrapperPath: finalPath))

            // Launch if requested
            let (shouldLaunch, args) = await context.shouldLaunchGame()
            if shouldLaunch {
                try await launchGame(at: finalPath, with: args)
            }

            return finalPath
            
        } catch {
            await bus.publishInstallation(.progress(.error(error.localizedDescription)))

            let installError = (error as? InstallationError) ?? .internalError(error.localizedDescription)
            await bus.publishInstallation(.failed(installError))
            
            await unmountAllISOs()
            
            gameInstaller.cleanupTemporaryWrappers()
            
            throw error
        }
    }
    
    // MARK: - Legacy Non-Interactive Installation (Deprecated - use performInstallation instead)
    
    /// Install game from disk sources in non-interactive mode (DEPRECATED - use performInstallation)
    /// - Parameters:
    ///   - disk1: URL to first disk (directory or ISO)
    ///   - disk2: Optional URL to second disk
    ///   - onDetectedGame: Callback when game is detected
    /// - Returns: URL of the created wrapper
    @available(*, deprecated, message: "Use performInstallation with NonInteractiveContext instead")
    func installFromDisk(
        disk1: URL,
        disk2: URL?,
        onDetectedGame: @escaping (GameInfo) -> Void
    ) async throws -> URL {
        logger.error("WARNING: Using deprecated installFromDisk method")
        let tempContext = NonInteractiveContext(
            environment: [
                "DISK_1_PATH": disk1.path,
                "DISK_2_PATH": disk2?.path ?? "",
                "OUTPUT_PATH": FileManager.default.temporaryDirectory.path
            ],
            viewModel: nil
        )

        var disk1Path: URL = disk1
        var disk2Path: URL? = nil

        if disk1.pathExtension.lowercased() == "iso" {
            disk1Path = try await mountISO(at: disk1, context: tempContext)
        }

        await bus.publishInstallation(.progress(.detectingGame(substep: nil)))

        if let gameSlug = try? await GameDetector.shared.detectGame(fromDisk: disk1Path) {
            let gameInfo = GameInfoProvider.shared.gameInfo(for: gameSlug)
            onDetectedGame(gameInfo)
            if gameInfo.diskCount > 1 && disk2 == nil {
                throw NSError(domain: "Installation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Game requires 2 disks but DISK_2_PATH was not provided"
                ])
            }
        }

        if let disk2 = disk2 {
            if disk2.pathExtension.lowercased() == "iso" {
                disk2Path = try await mountISO(at: disk2, context: tempContext)
            } else {
                disk2Path = disk2
            }
        }

        return try await gameInstaller.installFromDisk(
            disk1Path: disk1Path,
            disk2Path: disk2Path
        )
    }
    
    /// Save wrapper to specified location
    func saveWrapper(
        from wrapperPath: URL,
        to outputPath: URL,
        gameName: String
    ) async throws -> URL {
        let finalPath = outputPath.appendingPathComponent("Nancy Drew - \(gameName).app")
        
        logger.notice("Saving wrapper: \(finalPath.path, privacy: .public)")
        
        // Remove existing if present
        if FileManager.default.fileExists(atPath: finalPath.path) {
            try FileManager.default.removeItem(at: finalPath)
        }
        
        // Move wrapper
        try FileManager.default.moveItem(at: wrapperPath, to: finalPath)
        
        // Unregister from cleanup tracking since it's no longer temporary
        GameInstaller.shared.unregisterTemporaryWrapper(wrapperPath)
        
        logger.notice("Wrapper saved: \(finalPath.path, privacy: .public)")
        
        return finalPath
    }
    
    /// Launch the game app
    func launchGame(at appPath: URL, with arguments: [String]) async throws {
        let launchDesc = appPath.path + (arguments.isEmpty ? "" : " \(arguments.joined(separator: " "))")
        logger.notice("Launching: \(launchDesc, privacy: .public)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        
        // Build arguments: open <app-path> --args <app-arguments>
        var openArgs = [appPath.path]
        if !arguments.isEmpty {
            openArgs.append("--args")
            openArgs.append(contentsOf: arguments)
        }
        process.arguments = openArgs
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            logger.notice("Game launched successfully")
        } else {
            throw NSError(domain: "GameLaunch", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch game: open command exited with status \(process.terminationStatus)"
            ])
        }
    }
    
    /// Unmount all ISOs that were mounted by this service
    func unmountAllISOs() async {
        let mountedISOs = await mountedISOTracker.getAll()
        guard !mountedISOs.isEmpty else { return }
        
        logger.notice("Unmounting \(mountedISOs.count, privacy: .public) ISO(s)...")

        for mountPoint in mountedISOs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", mountPoint.path, "-quiet"]

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    logger.notice("Unmounted: \(mountPoint.path, privacy: .public)")
                } else {
                    logger.error("Failed to unmount \(mountPoint.path, privacy: .public) (exit code: \(process.terminationStatus, privacy: .public))")
                }
            } catch {
                logger.error("Error unmounting \(mountPoint.path, privacy: .public): \(error, privacy: .public)")
            }
        }
        
        await mountedISOTracker.removeAll()
    }
    
    // MARK: - ISO Management
    
    /// Mount an ISO file with context-aware sandbox handling
    /// Checks if already mounted, otherwise mounts to /Volumes
    private func mountISO(at isoPath: URL, context: InstallationContext) async throws -> URL {
        // Check if this ISO is already mounted
        if let existingMount = try? await checkIfISOAlreadyMounted(isoPath) {
            logger.notice("ISO already mounted: \(existingMount.path, privacy: .public)")
            return existingMount
        }

        logger.notice("Mounting ISO: \(isoPath.lastPathComponent, privacy: .public)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", isoPath.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ISOMount", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to mount ISO: \(errorOutput)"
            ])
        }
        
        // Parse hdiutil output to get mount point
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ISOMount", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read mount output"
            ])
        }
        
        // Find the mount point in the output (last column, usually /Volumes/...)
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let mountPoint = parts.last, mountPoint.hasPrefix("/") {
                var mountURL = URL(fileURLWithPath: mountPoint)
                
                // For sandboxed apps, may need user to grant access
                mountURL = try await context.requestVolumeAccess(mountPoint: mountURL)
                
                // Track that we mounted this
                await mountedISOTracker.insert(mountURL)
                logger.notice("Mounted: \(mountURL.path, privacy: .public)")
                return mountURL
            }
        }
        
        throw NSError(domain: "ISOMount", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to find mount point in hdiutil output"
        ])
    }
    
    /// Check if an ISO is already mounted and return its mount point
    private func checkIfISOAlreadyMounted(_ isoPath: URL) async throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        // Print any errors to console
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
            logger.fault("   hdiutil info error: \(errorOutput, privacy: .public)")
        }
        
        let plistData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        
        // Parse the plist
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            logger.notice("   ℹ️ No mounted disk images found")
            return nil
        }
        
        let fileManager = FileManager.default
        
        // Resolve the canonical path of our ISO (in case it's a symlink)
        let canonicalISOPath: String
        if let resolved = try? fileManager.destinationOfSymbolicLink(atPath: isoPath.path) {
            canonicalISOPath = (resolved as NSString).resolvingSymlinksInPath
            logger.notice("   ℹ️ Resolved symlink: \(isoPath.path, privacy: .public) -> \(canonicalISOPath, privacy: .public)")
        } else {
            canonicalISOPath = (isoPath.path as NSString).resolvingSymlinksInPath
        }
        
        logger.notice("   ℹ️ Looking for mounted ISO: \(canonicalISOPath, privacy: .public)")
        logger.notice("   ℹ️ Found \(images.count, privacy: .public) mounted disk image(s)")
        
        // Find our ISO in the list of mounted images
        for image in images {
            guard let imagePath = image["image-path"] as? String else {
                continue
            }
            
            let canonicalImagePath = (imagePath as NSString).resolvingSymlinksInPath
            
            logger.notice("   ℹ️ Checking mounted image: \(canonicalImagePath, privacy: .public)")
            
            if canonicalImagePath == canonicalISOPath {
                logger.notice("   ✓ Found matching mounted ISO")
                
                // Found our ISO, now get the mount points
                guard let systemEntities = image["system-entities"] as? [[String: Any]] else {
                    logger.error("   ⚠️ No system entities found for mounted ISO")
                    continue
                }
                
                for entity in systemEntities {
                    if let mountPoint = entity["mount-point"] as? String,
                       !mountPoint.isEmpty {
                        // Verify that the mount point actually exists as a directory
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: mountPoint, isDirectory: &isDirectory), isDirectory.boolValue {
                            logger.notice("   ✓ Mount point verified: \(mountPoint, privacy: .public)")
                            return URL(fileURLWithPath: mountPoint)
                        } else {
                            logger.error("   ⚠️ Mount point doesn't exist or isn't a directory: \(mountPoint, privacy: .public)")
                        }
                    }
                }
            }
        }
        
        logger.notice("   ℹ️ ISO not found in mounted images")
        return nil
    }
}
