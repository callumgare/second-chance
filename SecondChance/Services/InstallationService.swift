//
//  InstallationService.swift
//  SecondChance
//
//  Service for managing game installation without UI concerns

import Foundation
import Logging
import AppKit

/// Service for handling game installation logic without UI dependencies
/// Not tied to any actor, can be called from any context
class InstallationService {
    private let gameInstaller: GameInstaller
    let isoMounter: ISOMounter
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.InstallationService")

    init(bus: EventBus<AppEvent> = .app) {
        self.bus = bus
        self.gameInstaller = GameInstaller(bus: bus)
        self.isoMounter = ISOMounter()
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
            logger.notice("Disk 1: \(disk1.path)")

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
                    logger.notice("Disk 2: \(disk2.path)")
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
            await isoMounter.unmountAll()
            
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
            
            await isoMounter.unmountAll()
            
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
        
        logger.notice("Saving wrapper: \(finalPath.path)")
        
        // Remove existing if present
        if FileManager.default.fileExists(atPath: finalPath.path) {
            try FileManager.default.removeItem(at: finalPath)
        }
        
        // Move wrapper
        try FileManager.default.moveItem(at: wrapperPath, to: finalPath)
        
        // Unregister from cleanup tracking since it's no longer temporary
        GameInstaller.shared.unregisterTemporaryWrapper(wrapperPath)
        
        logger.notice("Wrapper saved: \(finalPath.path)")
        
        return finalPath
    }
    
    /// Launch the game app
    func launchGame(at appPath: URL, with arguments: [String]) async throws {
        let launchDesc = appPath.path + (arguments.isEmpty ? "" : " \(arguments.joined(separator: " "))")
        logger.notice("Launching: \(launchDesc)")
        
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
    
    /// Unmount all ISOs that were mounted by this service (delegates to ISOMounter)
    func unmountAllISOs() async {
        await isoMounter.unmountAll()
    }
    
    // MARK: - ISO Management
    
    /// Mount an ISO file with context-aware sandbox handling (delegates to ISOMounter)
    private func mountISO(at isoPath: URL, context: InstallationContext) async throws -> URL {
        try await isoMounter.mount(isoPath) { mountPoint in
            try await context.requestVolumeAccess(mountPoint: mountPoint)
        }
    }
    
}
