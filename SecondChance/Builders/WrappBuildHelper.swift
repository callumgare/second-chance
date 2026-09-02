//
//  WrappBuildHelper.swift
//  SecondChance
//
//  Source-independent helper functions for managing the wrapp-building
//  process. The per-source *WrappBuilder orchestrators call these; this
//  helper never calls a builder.
//
//  Merged from WrapperBuilder (bundle construction) + the InstallationService
//  tail (sign/save/launch). Disk-specific work (copying disk layouts, CD-ROM
//  mounting) lives in DiskWrappBuilder instead — it isn't shared.
//
//  Lifecycle rule: this helper provides cleanup *primitives* (e.g.
//  removeTempWrapp) for resources that outlive a single call — the builder
//  owns the lifecycle and decides when to call them. Resources created and
//  consumed entirely within one function are cleaned up inside that function
//  (both success and error paths) so builders never see them.
//

import Foundation
import Logging
import AppKit

/// Source-independent wrapp-building operations shared by every builder.
class WrappBuildHelper {
    static let shared = WrappBuildHelper()

    private let fileManager = FileManager.default
    private let wineManager: WineManager
    private let cacheManager: CacheManager
    let bus: EventBus<AppEvent>
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WrappBuildHelper")

    init(
        wineManager: WineManager = .shared,
        cacheManager: CacheManager = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.wineManager = wineManager
        self.cacheManager = cacheManager
        self.bus = bus
    }

    // MARK: - Base Wrapp Construction

    /// Copy directory using shell command with symlink preservation.
    /// This works around VirtualBuddy shared folder symlink issues.
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
            throw WrappError.copyFailed(message: "cp command failed", command: command, output: errorMessage)
        }
    }

    /// Create a base wrapp with both Wine and ScummVM support.
    func createBaseWrapp(at path: URL) async throws {
        // Check cache first
        if let _ = try cacheManager.restoreCache(stage: .base, to: path) {
            return
        }

        logger.notice("Creating unified wrapp with both Wine and ScummVM support...")
        await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))

        // Find the pre-built unified template
        guard let templatePath = Bundle.main.url(forResource: "GameWrapper", withExtension: "app") else {
            throw WrappError.templateNotFound("GameWrapper.app not found in Second Chance.app bundle")
        }

        // Copy the entire template (includes both Wine and ScummVM)
        do {
            try copyItemDerefencingSymlinks(at: templatePath, to: path)
        } catch {
            if let wrappError = error as? WrappError, let output = wrappError.copyOutput {
                logger.notice("Copy output: \(output)")
            }
            logger.critical("❌ Failed to copy GameWrapper template: \(error.localizedDescription)")
            if let wrappError = error as? WrappError, let command = wrappError.copyCommand {
                logger.notice("   Command: \(command)")
            }
            throw error
        }

        // Create Wine prefix (ScummVM doesn't need initialization)
        try await wineManager.createWinePrefix(at: path)

        // Save to cache
        try cacheManager.saveCache(wrappPath: path, stage: .base)
    }

    /// Remove the engine this game doesn't use from the wrapp.
    func cleanupUnusedEngine(at wrappPath: URL, gameEngine: GameInfo.GameEngine) throws {
        logger.notice("Cleaning up unused game engine from wrapp...")

        let resourcesPath = wrappPath.appendingPathComponent("Contents/Resources")

        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            // Using Wine, remove ScummVM files listed in scummvm-files
            let scummvmFilesPath = resourcesPath.appendingPathComponent("scummvm-files")
            if fileManager.fileExists(atPath: scummvmFilesPath.path) {
                logger.notice("Reading ScummVM files list...")
                if let content = try? String(contentsOf: scummvmFilesPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    logger.notice("Found \(lines.count) ScummVM files/directories to remove")

                    for relativePath in lines {
                        let pathToRemove = wrappPath.appendingPathComponent(relativePath)
                        if fileManager.fileExists(atPath: pathToRemove.path) {
                            try fileManager.removeItem(at: pathToRemove)
                        }
                    }
                }
            } else {
                logger.error("Warning: scummvm-files list not found at \(scummvmFilesPath.path)")
            }

        case .scummvm:
            // Using ScummVM, remove Wine files listed in wine-files
            let wineFilesPath = resourcesPath.appendingPathComponent("wine-files")
            if fileManager.fileExists(atPath: wineFilesPath.path) {
                logger.notice("Reading Wine files list...")
                if let content = try? String(contentsOf: wineFilesPath, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    logger.notice("Found \(lines.count) Wine files/directories to remove")

                    for relativePath in lines {
                        let pathToRemove = wrappPath.appendingPathComponent(relativePath)
                        if fileManager.fileExists(atPath: pathToRemove.path) {
                            try fileManager.removeItem(at: pathToRemove)
                        }
                    }
                }
            } else {
                logger.error("Warning: wine-files list not found at \(wineFilesPath.path)")
            }
        }

        logger.notice("Cleanup complete")
    }

    // MARK: - Wrapp Configuration

    /// Configure the wrapp for its game: rewrite Info.plist, write
    /// AppSettings.plist, remap the Documents symlink, patch game INIs.
    func configureWrapp(
        at wrappPath: URL,
        gameInfo: GameInfo,
        gameExePath: String,
        installerDir: String,
        steamID: String? = nil
    ) throws {
        Task { await bus.publishWrappBuild(.progress(.configuringWrapp(substep: "Updating configuration files"))) }

        let infoPlistPath = wrappPath.appendingPathComponent("Contents/Info.plist")

        // Update Info.plist
        guard let plistData = try? Data(contentsOf: infoPlistPath),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw WrappError.invalidInfoPlist
        }

        // Update bundle identifier by replacing GameWrapper with game ID
        guard let currentBundleID = plist["CFBundleIdentifier"] as? String else {
            throw WrappError.invalidInfoPlist
        }

        guard currentBundleID.contains("GameWrapper") else {
            throw WrappError.invalidInfoPlist
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
            at: wrappPath,
            gameInfo: gameInfo,
            gameExePath: gameExePath,
            installerDir: installerDir,
            steamID: steamID
        )

        // Remap documents folder to point to a namespaced dir in the user's Application Support
        // dir on the host computer. This documents symlink will likely be replaced with a more direct link when running
        // the game wrapp but we set this one up in case it's run on a read-only system.
        let prefixPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix")
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
        try configureGameINI(at: wrappPath, gameExePath: gameExePath)
    }

    /// Create AppSettings.plist for the runtime script to read
    private func createAppSettingsPlist(
        at wrappPath: URL,
        gameInfo: GameInfo,
        gameExePath: String,
        installerDir: String,
        steamID: String?
    ) throws {
        let resourcesPath = wrappPath.appendingPathComponent("Contents/Resources")
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

        logger.notice("Created AppSettings.plist with engine: \(gameEngine)")
    }

    /// Configure game INI files
    private func configureGameINI(at wrappPath: URL, gameExePath: String) throws {
        // Build the full path to the game directory within the wrapp
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")

        // gameExePath is a Windows path like "/Program Files (x86)/Nancy Drew/Game/game.exe"
        // Remove leading slash and append to drive_c
        let cleanGameExePath = gameExePath.hasPrefix("/") ? String(gameExePath.dropFirst()) : gameExePath
        let gameExeURL = driveCPath.appendingPathComponent(cleanGameExePath)
        let gameDir = gameExeURL.deletingLastPathComponent()

        logger.notice("Configuring game INI files in: \(gameDir.path)")

        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gameDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("⚠️ Warning: Game directory not found at \(gameDir.path)")
            return
        }

        // Find INI files in game directory
        let contents = try? fileManager.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: nil,
            options: []
        )

        guard let contents else {
            logger.error("⚠️ Warning: Failed to read game directory at \(gameDir.path)")
            return
        }

        let iniFiles = contents.filter({ $0.pathExtension.lowercased() == "ini" })

        if iniFiles.isEmpty {
            logger.error("⚠️ No INI files found in game directory")
            logger.notice("   Files found in directory:")
            for file in contents {
                logger.notice("     - \(file.lastPathComponent)")
            }
            return
        }

        logger.notice("Found \(iniFiles.count) INI file\(iniFiles.count == 1 ? "" : "s") to configure")

        for iniFile in iniFiles {
            logger.notice("  Processing: \(iniFile.lastPathComponent)")

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
                logger.notice("       Old: \(oldValue)")
                logger.notice("       New: \(savePath)")
                modified = true
            } else {
                logger.notice("    ℹ️ No LoadSavePath setting found")
            }

            // Write back if modified
            if modified {
                do {
                    try content.write(to: iniFile, atomically: true, encoding: .utf8)
                    logger.notice("    ✅ Saved changes to \(iniFile.lastPathComponent)")
                } catch {
                    logger.error("    ⚠️ Failed to save changes: \(error)")
                }
            } else {
                logger.notice("    ℹ️ No changes needed")
            }
        }
    }

    // MARK: - Steam Client

    /// Install the Steam client in the wrapp (used by SteamWrappBuilder).
    func installSteamClient(in wrappPath: URL) async throws {
        // Check cache first
        if let _ = try cacheManager.restoreCache(stage: .steamClientInstalled, to: wrappPath) {
            return
        }

        await bus.publishWrappBuild(.progress(.installingGame(substep: "Installing Steam client")))

        // Stop wine server first
        let wine = WineEnvironment(appPath: wrappPath)
        _ = wine.stopWineserver()

        // Install Steam via winetricks
        try await wineManager.installWinetrick("steam", at: wrappPath)

        // Save to cache
        try cacheManager.saveCache(wrappPath: wrappPath, stage: .steamClientInstalled)
    }

    // MARK: - Finalization (absorbed from InstallationService)

    /// Sequence the tail of every build: sign → resolve output → save →
    /// notify completion. Publishes `.signed` and `.completed`; emits
    /// `.savingApp` progress (the disk flow previously never did).
    ///
    /// The caller (builder) still owns unmounting ISOs it mounted — that is
    /// source-specific, not part of the shared tail.
    func finalize(
        wrapp wrappPath: URL,
        gameInfo: GameInfo,
        input: WrappBuildInput
    ) async throws -> URL {
        // Sign before moving so failures trigger the builder's cleanup
        try signWrapp(at: wrappPath)
        await bus.publishWrappBuild(.signed(wrappPath: wrappPath))

        await bus.publishWrappBuild(.progress(.savingApp(substep: nil)))
        let outputDir = try await input.getOutputPath(gameName: gameInfo.title)
        let finalPath = try await saveWrapp(
            from: wrappPath,
            to: outputDir,
            gameName: gameInfo.title
        )

        await input.onWrappBuildComplete(finalPath)
        await bus.publishWrappBuild(.completed(wrappPath: finalPath))

        return finalPath
    }

    /// Sign the wrapp app (ad-hoc codesign).
    func signWrapp(at path: URL) throws {
        logger.notice("Signing wrapp...")

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
            logger.notice("✅ Wrapp signed successfully")
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            let command = "\(codesignPath) \(process.arguments?.joined(separator: " ") ?? "")"
            logger.error("⚠️ Code signing failed: \(errorMessage)")
            logger.notice("   Command: \(command)")
            throw WrappError.signingFailed(errorMessage)
        }
    }

    /// Move the finished wrapp to its output location and unregister it from
    /// cleanup tracking (it's no longer temporary).
    func saveWrapp(
        from wrappPath: URL,
        to outputPath: URL,
        gameName: String
    ) async throws -> URL {
        let finalPath = outputPath.appendingPathComponent("Nancy Drew - \(gameName).app")

        logger.notice("Saving wrapp: \(finalPath.path)")

        // Remove existing if present
        if FileManager.default.fileExists(atPath: finalPath.path) {
            try FileManager.default.removeItem(at: finalPath)
        }

        // Move wrapp
        try FileManager.default.moveItem(at: wrappPath, to: finalPath)

        logger.notice("Wrapp saved: \(finalPath.path)")

        return finalPath
    }

    // MARK: - Temp Wrapp Tracking (cleanup primitives)

    private var temporaryWrapps: Set<URL> = []
    private let wrappsLock = NSLock()

    /// Create a fresh temporary wrapp path and register it for cleanup.
    func createTemporaryWrappPath() -> URL {
        let tempDir = fileManager.temporaryDirectory
        let wrappName = "NancyDrew-\(UUID().uuidString).app"
        let path = tempDir.appendingPathComponent(wrappName)
        registerTemporaryWrapp(path)
        return path
    }

    /// Register a temporary wrapp for tracking
    private func registerTemporaryWrapp(_ path: URL) {
        wrappsLock.lock()
        defer { wrappsLock.unlock() }
        temporaryWrapps.insert(path)
    }

    /// Unregister a temporary wrapp (call after successful move/save)
    func unregisterTemporaryWrapp(_ path: URL) {
        wrappsLock.lock()
        defer { wrappsLock.unlock() }
        temporaryWrapps.remove(path)
    }

    /// Remove one tracked temp wrapp — a cleanup *primitive* the builder
    /// calls on its error path. No-op if already moved or removed.
    func removeTempWrapp(_ path: URL) {
        wrappsLock.lock()
        temporaryWrapps.remove(path)
        wrappsLock.unlock()

        guard fileManager.fileExists(atPath: path.path) else { return }

        if DebugSettings.shared.debugMode {
            logger.notice("🐛 DEBUG: Keeping temp wrapp for inspection: \(path.path)")
            return
        }

        do {
            try fileManager.removeItem(at: path)
            logger.notice("🧹 Removed temp wrapp: \(path.lastPathComponent)")
        } catch {
            logger.error("   ⚠️ Failed to remove \(path.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Clean up all tracked temporary wrapps (app termination / crash paths).
    func cleanupTemporaryWrapps() {
        wrappsLock.lock()
        let wrapps = Array(temporaryWrapps)
        temporaryWrapps.removeAll()
        wrappsLock.unlock()

        guard !wrapps.isEmpty else { return }

        // Skip deletion in debug mode
        if DebugSettings.shared.debugMode {
            logger.notice("🐛 DEBUG: Keeping \(wrapps.count) temporary wrapp(s) for inspection:")
            for wrapp in wrapps {
                if fileManager.fileExists(atPath: wrapp.path) {
                    logger.notice("   \(wrapp.path)")
                }
            }
            return
        }

        logger.notice("🧹 Cleaning up \(wrapps.count) temporary wrapp(s)...")
        for wrapp in wrapps {
            do {
                if fileManager.fileExists(atPath: wrapp.path) {
                    logger.notice("   Removing: \(wrapp.path)")
                    try fileManager.removeItem(at: wrapp)
                }
            } catch {
                logger.error("   ⚠️ Failed to remove \(wrapp.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Launch

    /// Launch the finished wrapp (headless automation support).
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
}

// MARK: - Errors

enum WrappError: LocalizedError {
    case cachedGameMismatch
    case invalidInfoPlist
    case wineNotFound
    case templateNotFound(String)
    case copyFailed(message: String, command: String?, output: String?)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .cachedGameMismatch:
            return "Cached wrapp belongs to a different game"
        case .invalidInfoPlist:
            return "Wrapp Info.plist is missing required keys or has an unexpected bundle identifier"
        case .wineNotFound:
            return "Wine binary not found in wrapp"
        case .templateNotFound(let message):
            return message
        case .copyFailed(let message, _, _):
            return message
        case .signingFailed(let message):
            return "Code signing failed: \(message)"
        }
    }

    var copyCommand: String? {
        if case let .copyFailed(_, command, _) = self { return command }
        return nil
    }

    var copyOutput: String? {
        if case let .copyFailed(_, _, output) = self { return output }
        return nil
    }
}
