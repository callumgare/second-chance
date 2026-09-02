//
//  DiskWrappBuilder.swift
//  SecondChance
//
//  The per-source orchestrator for building a wrapp from game disks (real
//  CDs, folders, or ISO images). Owns the disk flow end-to-end.
//
//  GameInfo is detected ONCE here and threaded through the rest of the
//  flow — nothing downstream re-runs detection.
//
//  Resource ownership (per the design rules): this builder mounts ISOs and
//  creates the temp wrapp, so it tears both down on the success AND error
//  paths, wrapped in do/catch.
//

import Foundation
import Logging

/// Builds a wrapp from game disks.
///
/// Owns the disk-specific layout (`disk-1` / `disk-2` / `disk-combined`
/// under `drive_c/nancy-drew-installer/`) and the ISO mount/unmount
/// lifecycle. Calls shared helpers (WrappBuildHelper, GameInstallerRunner)
/// for everything source-independent.
final class DiskWrappBuilder: WrappBuildStrategy {
    private let helper: WrappBuildHelper
    private let installerRunner: GameInstallerRunner
    private let gameDetector: GameDetector
    private let gameInfoProvider: GameInfoProvider
    private let isoMounter: ISOMounter
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.DiskWrappBuilder")

    init(
        helper: WrappBuildHelper = .shared,
        installerRunner: GameInstallerRunner = .shared,
        gameDetector: GameDetector = .shared,
        gameInfoProvider: GameInfoProvider = .shared,
        isoMounter: ISOMounter = ISOMounter(),
        bus: EventBus<AppEvent> = .app
    ) {
        self.helper = helper
        self.installerRunner = installerRunner
        self.gameDetector = gameDetector
        self.gameInfoProvider = gameInfoProvider
        self.isoMounter = isoMounter
        self.bus = bus
    }

    // MARK: - Build Flow

    func build(input: WrappBuildInput) async throws -> URL {
        await bus.publishWrappBuild(.started(source: .disk))

        // ── Resolve disks ──────────────────────────────────────────────
        let disk1 = try await input.getDisk1Path()
        logger.notice("Disk 1: \(disk1.path)")

        let disk1Mounted = try await mountIfISO(disk1, input: input)
        if let mounted = disk1Mounted {
            await bus.publishWrappBuild(.isoMounted(mounted))
        }
        let disk1Root = disk1Mounted ?? disk1

        // ── Detect the game ONCE; GameInfo threads through from here ──
        await bus.publishWrappBuild(.progress(.detectingGame(substep: nil)))
        let gameSlug = try await gameDetector.detectGame(fromDisk: disk1Root)
        let gameInfo = gameInfoProvider.gameInfo(for: gameSlug)
        logger.notice("Detected game: \(gameInfo.title)")
        await bus.publishWrappBuild(.gameDetected(gameInfo))
        await input.onGameDetected(gameInfo)

        // ── Disk 2 (multi-disk games) ─────────────────────────────────
        var disk2Root: URL?
        if gameInfo.diskCount > 1 {
            if let disk2 = try await input.getDisk2Path(gameInfo: gameInfo) {
                logger.notice("Disk 2: \(disk2.path)")
                if let mounted = try await mountIfISO(disk2, input: input) {
                    await bus.publishWrappBuild(.isoMounted(mounted))
                    disk2Root = mounted
                } else {
                    disk2Root = disk2
                }
            }
        }

        await bus.publishWrappBuild(.disksResolved(disk1: disk1Root, disk2: disk2Root))

        // ── Build ──────────────────────────────────────────────────────
        // The builder owns the temp wrapp lifecycle: removed on both the
        // success path (after the move in finalize) and on error.
        let wrappPath = helper.createTemporaryWrappPath()
        logger.notice("Temporary wrapp: \(wrappPath.path)")

        do {
            try await helper.createBaseWrapp(at: wrappPath)

            // Disk-specific layout + CD-ROM mounting stays in the builder —
            // no other source uses it.
            try await copyGameDisks(
                disk1: disk1Root,
                disk2: disk2Root,
                to: wrappPath,
                gameSlug: gameSlug
            )

            // Install the game via the engine it actually uses.
            await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
            let (gameExePath, installerDir): (String, String)
            switch gameInfo.gameEngine {
            case .wine:
                await bus.publishWrappBuild(.engineRouted(engine: .wine, gameInfo: gameInfo))
                (gameExePath, installerDir) = try await installerRunner.installGameWithWine(
                    wrappPath: wrappPath,
                    gameInfo: gameInfo
                )
            case .scummvm:
                await bus.publishWrappBuild(.engineRouted(engine: .scummvm, gameInfo: gameInfo))
                (gameExePath, installerDir) = try await installerRunner.installGameWithScummVM(
                    wrappPath: wrappPath,
                    gameInfo: gameInfo
                )
            default:
                throw WrappBuildError.unsupportedEngine
            }

            // Clean up unused engine unless we skipped the installer — wine
            // might be needed to run the installer later.
            if !DebugSettings.shared.skipInstaller {
                try helper.cleanupUnusedEngine(at: wrappPath, gameEngine: gameInfo.gameEngine)
            }

            try helper.configureWrapp(
                at: wrappPath,
                gameInfo: gameInfo,
                gameExePath: gameExePath,
                installerDir: installerDir
            )
            await bus.publishWrappBuild(.wrappConfigured(
                exePath: gameExePath,
                installerDir: installerDir,
                gameInfo: gameInfo
            ))

            // ── Shared tail: sign → save → notify. The move in here makes ──
            // the temp wrapp non-temporary, so unregister on success.
            let finalPath = try await helper.finalize(wrapp: wrappPath, gameInfo: gameInfo, input: input)
            helper.unregisterTemporaryWrapp(wrappPath)

            // Builder-owned resources: unmount now the build is complete.
            await isoMounter.unmountAll()

            // Launch if requested (headless automation).
            let (shouldLaunch, args) = await input.shouldLaunchGame()
            if shouldLaunch {
                try await helper.launchGame(at: finalPath, with: args)
            }

            return finalPath
        } catch {
            // Tear down builder-owned resources before rethrowing.
            helper.removeTempWrapp(wrappPath)
            await isoMounter.unmountAll()

            let installError = (error as? WrappBuildError) ?? .internalError(error.localizedDescription)
            await bus.publishWrappBuild(.failed(installError))
            throw error
        }
    }

    // MARK: - ISO Lifecycle (builder-owned)

    /// Mount the given disk if it's an ISO. Returns the mount point, or nil
    /// when the path was already a directory.
    private func mountIfISO(_ disk: URL, input: WrappBuildInput) async throws -> URL? {
        guard disk.pathExtension.lowercased() == "iso" else { return nil }
        return try await isoMounter.mount(disk) { mountPoint in
            try await input.requestVolumeAccess(mountPoint: mountPoint)
        }
    }

    // MARK: - Disk Layout (disk-specific; not shared with other sources)

    private let fileManager = FileManager.default
    private let wineManager = WineManager.shared
    private let cacheManager = CacheManager.shared

    /// Copy game installer disks into the wrapp: disk-1, optional disk-2,
    /// and the disk-combined symlink view for multi-disk games. Mounts the
    /// disk directories as Wine CD-ROM drives.
    private func copyGameDisks(
        disk1: URL,
        disk2: URL?,
        to wrappPath: URL,
        gameSlug: String
    ) async throws {
        // Check cache first
        if let metadata = try cacheManager.restoreCache(stage: .diskGameInstallerCopied, to: wrappPath) {
            if metadata.gameSlug == gameSlug {
                return
            } else {
                throw WrappError.cachedGameMismatch
            }
        }

        await bus.publishWrappBuild(.progress(.copyingInstaller(substep: nil)))

        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
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
                logger.notice("✅ Copied setup.iss for \(gameSlug)")
            } catch {
                logger.error("⚠️ Failed to copy setup.iss: \(error)")
            }
        } else {
            logger.notice("ℹ️ No setup.iss file found for \(gameSlug)")
        }

        // Mount the disk directories as CD-ROM drives
        // (Don't report progress again - would cause duplicate print)
        try await mountGameDisksIntoWine(wrappPath: wrappPath)

        // Save to cache
        try cacheManager.saveCache(wrappPath: wrappPath, stage: .diskGameInstallerCopied, gameSlug: gameSlug)
    }

    /// Mount game disk directories as CD-ROM drives
    private func mountGameDisksIntoWine(wrappPath: URL) async throws {
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
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

        logger.notice("Found \(diskDirs.count) disk director\(diskDirs.count == 1 ? "y" : "ies") to mount as CD-ROM drives")

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

            logger.notice("Mounting disk-\(disk.number) as \(letter): (cdrom)")
            try await wineManager.mountDirectory(
                relativePath,
                asDrive: letter,
                type: "cdrom",
                in: wrappPath
            )
        }
    }

    /// Remove extended attributes, resource forks, and Finder info that
    /// would cause codesign to fail.
    private func removeExtendedAttributes(from path: URL) throws {
        logger.notice("Removing extended attributes from \(path.lastPathComponent)...")

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
            logger.error("⚠️ Failed to remove extended attributes: \(errorMessage)")
            // Don't throw - this is not critical, codesign will just fail later with a better message
        }
    }
}
