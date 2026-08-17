//
//  GameInstaller.swift
//  SecondChance
//
//  Orchestrates the complete game installation process

import Foundation
import Logging
import AppKit

/// Orchestrates the complete Nancy Drew game installation process
class GameInstaller {
    static let shared = GameInstaller()

    private let fileManager = FileManager.default
    private let wrapperBuilder = WrapperBuilder.shared
    private let gameDetector = GameDetector.shared
    private let gameInfoProvider = GameInfoProvider.shared
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstaller")
    let bus: EventBus<AppEvent>

    /// Runs the game's own installer and locates the result — all
    /// installer-execution machinery lives here.
    private let installerRunner: GameInstallerRunner

    // Track temporary wrappers for cleanup
    private var temporaryWrappers: Set<URL> = []
    private let wrappersLock = NSLock()

    init(bus: EventBus<AppEvent> = .app) {
        self.bus = bus
        self.installerRunner = GameInstallerRunner(bus: bus)
    }
    
    // MARK: - Main Installation Flow
    
    /// Install game from disks
    func installFromDisk(
        disk1Path: URL,
        disk2Path: URL?
    ) async throws -> URL {
        // Detect game
        logger.notice("Analyzing disk: \(disk1Path.lastPathComponent)")
        let gameSlug = try await gameDetector.detectGame(fromDisk: disk1Path)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        logger.notice("Detected game: \(gameInfo.title)")
        await bus.publishInstallation(.gameDetected(gameInfo))

        // Create wrapper (WrapperBuilder will report progress for setup)
        let wrapperPath = createTemporaryWrapperPath()
        registerTemporaryWrapper(wrapperPath)
        logger.notice("Temporary wrapper: \(wrapperPath.path)")
        
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
                (gameExePath, installerDir) = try await installerRunner.installGameWithWine(
                    wrapperPath: wrapperPath,
                    gameInfo: gameInfo
                )
            } else if gameInfo.gameEngine == .scummvm {
                await bus.publishInstallation(.engineRouted(engine: .scummvm, gameInfo: gameInfo))
                (gameExePath, installerDir) = try await installerRunner.installGameWithScummVM(
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
        logger.notice("Detected game: \(gameInfo.title)")
        
        // Create wrapper (WrapperBuilder will report progress for setup)
        let wrapperPath = createTemporaryWrapperPath()
        registerTemporaryWrapper(wrapperPath)
        logger.notice("Temporary wrapper: \(wrapperPath.path)")

        do {
            try await wrapperBuilder.createBaseWrapper(at: wrapperPath)

            // Install game
            Task { await self.bus.publishInstallation(.progress(.installingGame(substep: nil))) }
            let (gameExePath, installerDir) = try await installerRunner.installGameWithWine(
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
        logger.notice("Temporary wrapper: \(wrapperPath.path)")
        try await wrapperBuilder.createBaseWrapper(at: wrapperPath)
        Task { await self.bus.publishInstallation(.progress(.installingGame(substep: nil))) }
        try await wrapperBuilder.installSteamClient(in: wrapperPath)
        
        // User installs game through Steam UI
        // This would need to launch Steam and wait for user to install
        // For now, this is a simplified version
        
        throw InstallationError.steamNotFullyImplemented
    }
    
    // MARK: - Temporary Wrapper Tracking

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
            logger.notice("🐛 DEBUG: Keeping \(wrappers.count) temporary wrapper(s) for inspection:")
            for wrapper in wrappers {
                if fileManager.fileExists(atPath: wrapper.path) {
                    logger.notice("   \(wrapper.path)")
                }
            }
            return
        }
        
        logger.notice("🧹 Cleaning up \(wrappers.count) temporary wrapper(s)...")
        for wrapper in wrappers {
            do {
                if fileManager.fileExists(atPath: wrapper.path) {
                    logger.notice("   Removing: \(wrapper.path)")
                    try fileManager.removeItem(at: wrapper)
                }
            } catch {
                logger.error("   ⚠️ Failed to remove \(wrapper.lastPathComponent): \(error.localizedDescription)")
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
    case userCancelledBeforeStart
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
        case .userCancelledBeforeStart:
            return "Installation cancelled before it started"
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
}
