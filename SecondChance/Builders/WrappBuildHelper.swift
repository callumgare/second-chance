//
//  WrappBuildHelper.swift
//  SecondChance
//
//  Source-independent helper functions for managing the wrapp-building
//  process. The per-source *WrappBuilder orchestrators call these; this
//  helper never calls a builder.
//
//  Covers bundle construction and the sign/save/launch tail. Disk-specific
//  work (copying disk layouts, CD-ROM mounting) lives in DiskWrappBuilder
//  instead — it isn't shared.
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

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.WrappBuildHelper")

/// Source-independent wrapp-building operations shared by every builder.
class WrappBuildHelper {
    static let shared = WrappBuildHelper()

    private let fileManager = FileManager.default
    private let wineManager: WineManager
    private let cacheManager: CacheManager
    let bus: EventBus<AppEvent>

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
    private func copyItemDerefencingSymlinks(at source: URL, to destination: URL) async throws {
        let executable = "/bin/cp"
        // -a: recursive, preserving symlinks (not following them) and attributes
        let arguments = ["-a", source.path, destination.path]
        let copy = try await Process.output(of: executable, arguments)
        if !copy.succeeded {
            let command = formatShellCommand(executable: executable, arguments: arguments)
            throw WrappError.copyFailed(message: "cp command failed", command: command, output: copy.errorOutput)
        }
    }

    /// Create a base wrapp with both Wine and ScummVM support.
    func createBaseWrapp(at path: URL) async throws {
        // Find the pre-built unified template
        guard let templatePath = Bundle.main.url(forResource: "WrappTemplate", withExtension: "app") else {
            throw WrappError.templateNotFound("WrappTemplate.app not found in Second Chance.app bundle")
        }
        // Before the cache too: a cached base wrapp came from this template.
        try await verifyTemplateSignatures(templatePath)

        // Check cache first
        if try cacheManager.restoreCache(stage: .base, to: path) != nil {
            return
        }

        logger.notice("Creating unified wrapp with both Wine and ScummVM support...")
        await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))

        // Copy the entire template (includes both Wine and ScummVM)
        do {
            try await copyItemDerefencingSymlinks(at: templatePath, to: path)
        } catch {
            if let wrappError = error as? WrappError, let output = wrappError.copyOutput {
                logger.notice("Copy output: \(output)")
            }
            logger.critical("❌ Failed to copy wrapp template: \(error.localizedDescription)")
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

    /// Fail now, rather than at signing minutes later, if the template's
    /// files have lost their code signatures. A file that isn't Mach-O (the
    /// Windows DLLs under `Frameworks/renderer/`, say) keeps its signature in
    /// extended attributes, so a copy of Second Chance made with something
    /// that drops them (rsync without -E or -X, scp, a zip not made with
    /// ditto) leaves those files unsigned, and `signWrapp` then fails with
    /// "code object is not signed at all". `codesign --verify` on the
    /// template says the same in under a second. Only that failure stops the
    /// build: anything else it reports is logged, since a wrapp is re-signed
    /// whole at the end anyway.
    func verifyTemplateSignatures(_ templatePath: URL) async throws {
        let verify: ProcessOutput
        do {
            verify = try await Process.output(of: "/usr/bin/codesign", ["--verify", templatePath.path])
        } catch {
            logger.warning("Couldn't run codesign to check the wrapp template: \(error.localizedDescription)")
            return
        }
        let output = verify.errorOutput
        guard !verify.succeeded else { return }
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("code object is not signed at all") {
            logger.critical("❌ The wrapp template has files without their code signatures: \(detail)")
            throw WrappError.templateSignaturesLost(detail)
        }
        logger.warning("codesign --verify reports a problem with the wrapp template, carrying on: \(detail)")
    }

    /// Remove the engine this game doesn't use from the wrapp.
    func cleanupUnusedEngine(at wrappPath: URL, gameEngine: GameInfo.GameEngine) async throws {
        logger.notice("Cleaning up unused game engine from wrapp...")

        let resourcesPath = wrappPath.appendingPathComponent("Contents/Resources")

        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            try await removeEngineFiles(listedIn: resourcesPath.appendingPathComponent("scummvm-files"),
                                  engine: "ScummVM", from: wrappPath)
        case .scummvm:
            try await removeEngineFiles(listedIn: resourcesPath.appendingPathComponent("wine-files"),
                                  engine: "Wine", from: wrappPath)
        }

        logger.notice("Cleanup complete")
    }

    /// Remove what an engine list names. The lists are written by
    /// `setup-wine.sh` and `setup-scummvm.sh` with the engine's files,
    /// relative to the bundle's `Contents/`, and ship in the template's
    /// Resources.
    ///
    /// They list regular files only, so removing just those would leave
    /// framework skeletons and versioned-dylib symlinks behind, which
    /// codesign rejects ("bundle format unrecognized"). Each listed entry is
    /// removed whole at its top two levels (`Frameworks/GStreamer.framework`,
    /// `SharedSupport/wine`, `MacOS/scummvm`) — the two engines share none of
    /// those — and then any symlink left pointing at nothing.
    func removeEngineFiles(listedIn list: URL, engine: String, from wrappPath: URL) async throws {
        try await Blocking.run { try Self.removeEngineFilesNow(listedIn: list, engine: engine, from: wrappPath) }
    }

    /// Gigabytes, for Wine: `removeEngineFiles` runs it off the main thread.
    private nonisolated static func removeEngineFilesNow(listedIn list: URL, engine: String, from wrappPath: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: list.path) else {
            logger.warning("No \(engine) file list at \(list.path) — leaving \(engine) in the wrapp")
            return
        }
        let content = try String(contentsOf: list, encoding: .utf8)
        let entries = Set(content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.split(separator: "/").prefix(2).joined(separator: "/") })
        let contents = wrappPath.appendingPathComponent("Contents")
        let before = DirectorySize.measure(contents)
        for entry in entries.sorted() {
            let path = contents.appendingPathComponent(entry)
            if (try? path.checkResourceIsReachable()) == true || isSymlink(path) {
                try fileManager.removeItem(at: path)
            }
        }
        for dir in ["Frameworks", "MacOS", "Resources", "SharedSupport"] {
            removeDanglingSymlinks(in: contents.appendingPathComponent(dir))
        }
        let after = DirectorySize.measure(contents)
        let freed = ByteCountFormatter.string(fromByteCount: before.bytes - after.bytes, countStyle: .file)
        logger.notice("Removed \(engine), which the game doesn't use: \(entries.count) entries, \(freed)")
    }

    private nonisolated static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Remove symlinks directly in `directory` whose target no longer exists.
    private nonisolated static func removeDanglingSymlinks(in directory: URL) {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items where isSymlink(item) && !fileManager.fileExists(atPath: item.path) {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                logger.warning("Can't remove the dangling symlink \(item.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Installer Answer Files

    /// Copy the InstallShield answer file for `gameSlug` to `setup.iss` in
    /// `installerBaseDir` (the wrapp's `drive_c/nancy-drew-installer`), where
    /// `GameInstallerRunner` looks for one to run the installer silently.
    ///
    /// Answer files live in the bundle's `installer-answer-files`, the discs'
    /// at its top level and other sources' in a subdirectory named after the
    /// source (`her-download/`), since a download's installer asks different
    /// questions from the disc's. Returns whether there was one to copy; a
    /// game without one installs interactively.
    @discardableResult
    func installAnswerFile(forGame gameSlug: String, source: WrappSource, into installerBaseDir: URL) -> Bool {
        let directory = source == .disk ? "installer-answer-files" : "installer-answer-files/\(source.rawValue)"
        guard let issPath = Bundle.main.path(forResource: gameSlug, ofType: "iss", inDirectory: directory) else {
            logger.notice("ℹ️ No setup.iss in \(directory) for \(gameSlug)")
            return false
        }
        let destination = installerBaseDir.appendingPathComponent("setup.iss")
        do {
            try fileManager.createDirectory(at: installerBaseDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(atPath: issPath, toPath: destination.path)
            logger.notice("✅ Copied \(directory)/\(gameSlug).iss to setup.iss")
            return true
        } catch {
            logger.warning("⚠️ Failed to copy setup.iss: \(error)")
            return false
        }
    }

    // MARK: - Wrapp Configuration

    /// Configure the wrapp for its game: rewrite Info.plist, write
    /// AppSettings.plist, remap the Documents symlink, patch game INIs.
    func configureWrapp(
        at wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource,
        gameExePath: String,
        installerDir: String,
        steamID: String? = nil,
        gameEngine: GameInfo.GameEngine? = nil,
        steamLaunchMode: GameInfo.SteamLaunchMode? = nil
    ) throws {
        Task { await bus.publishWrappBuild(.progress(.configuringWrapp(substep: "Adjusting the game's settings"))) }

        let infoPlistPath = wrappPath.appendingPathComponent("Contents/Info.plist")

        // Update Info.plist
        guard let plistData = try? Data(contentsOf: infoPlistPath),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw WrappError.invalidInfoPlist
        }

        // Update bundle identifier by replacing WrappTemplate with game ID
        guard let currentBundleID = plist["CFBundleIdentifier"] as? String else {
            throw WrappError.invalidInfoPlist
        }

        guard currentBundleID.contains("WrappTemplate") else {
            throw WrappError.invalidInfoPlist
        }

        let newBundleID = currentBundleID.replacingOccurrences(of: "WrappTemplate", with: "nancy-drew." + gameInfo.id)
        plist["CFBundleIdentifier"] = newBundleID
        plist["CFBundleName"] = "Nancy Drew - \(gameInfo.title)"
        plist["CFBundleDisplayName"] = "Nancy Drew - \(gameInfo.title)"
        plist["GameExePath"] = gameExePath
        plist["Program Name and Path"] = gameExePath
        // Where a failed launch looks for a newer Second Chance (NewerRelease).
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String {
            plist[NewerRelease.feedURLKey] = feed
        } else {
            logger.warning("Second Chance has no SUFeedURL; the wrapp won't check for a newer version when it fails")
        }

        // Save updated plist
        let updatedData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updatedData.write(to: infoPlistPath)

        // Create AppSettings.plist for runtime script
        try createAppSettingsPlist(
            at: wrappPath,
            gameInfo: gameInfo,
            source: source,
            gameExePath: gameExePath,
            installerDir: installerDir,
            steamID: steamID,
            gameEngine: gameEngine ?? gameInfo.gameEngine,
            steamLaunchMode: steamLaunchMode
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
        source: WrappSource,
        gameExePath: String,
        installerDir: String,
        steamID: String?,
        gameEngine engine: GameInfo.GameEngine,
        steamLaunchMode: GameInfo.SteamLaunchMode?
    ) throws {
        let resourcesPath = wrappPath.appendingPathComponent("Contents/Resources")
        let appSettingsPath = resourcesPath.appendingPathComponent("AppSettings.plist")

        // Ensure Resources directory exists
        if !fileManager.fileExists(atPath: resourcesPath.path) {
            try fileManager.createDirectory(at: resourcesPath, withIntermediateDirectories: true)
        }

        // Convert GameEngine enum to string for config
        let gameEngine: String
        switch engine {
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
            "GameSource": source.rawValue,
            "GameInstallerDir": installerDir
        ]

        // Add Steam ID if present
        if let steamID = steamID {
            settings["SteamGameId"] = steamID
        }
        if let steamLaunchMode {
            settings["SteamLaunchMode"] = steamLaunchMode.rawValue
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
            logger.warning("⚠️ Warning: Game directory not found at \(gameDir.path)")
            return
        }

        // Find INI files in game directory
        let contents = try? fileManager.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: nil,
            options: []
        )

        guard let contents else {
            logger.warning("⚠️ Warning: Failed to read game directory at \(gameDir.path)")
            return
        }

        let iniFiles = contents.filter({ $0.pathExtension.lowercased() == "ini" })

        if iniFiles.isEmpty {
            // Normal for ScummVM games and some installers: nothing to configure.
            logger.notice("No INI files to configure in the game directory")
            logger.debug("   Files found in directory:")
            for file in contents {
                logger.debug("     - \(file.lastPathComponent)")
            }
            return
        }

        logger.notice("Found \(iniFiles.count) INI file\(iniFiles.count == 1 ? "" : "s") to configure")

        for iniFile in iniFiles {
            logger.notice("  Processing: \(iniFile.lastPathComponent)")

            guard let originalContent = try? String(contentsOf: iniFile, encoding: .utf8) else {
                logger.warning("    ⚠️ Failed to read file")
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
                    logger.warning("    ⚠️ Failed to save changes: \(error)")
                }
            } else {
                logger.notice("    ℹ️ No changes needed")
            }
        }
    }

    // MARK: - Steam Client

    static let steamInstallerURL = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"

    /// Valve's Steam installer, downloaded once into the caches directory.
    /// It only lays down a bootstrapper that updates itself on first start,
    /// so an old copy is as good as a new one.
    func steamInstaller() async throws -> URL {
        let cached = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/SteamSetup.exe")
        if fileManager.fileExists(atPath: cached.path) { return cached }
        guard let url = URL(string: Self.steamInstallerURL) else {
            throw WrappBuildError.internalError("Bad Steam installer URL: \(Self.steamInstallerURL)")
        }
        logger.notice("Downloading the Steam installer from \(url.absoluteString)")
        let (download, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WrappBuildError.internalError("Couldn't download the Steam installer (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        try fileManager.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: cached)
        try fileManager.moveItem(at: download, to: cached)
        return cached
    }

    /// Install the Steam client in the wrapp (used by SteamWrappBuilder).
    func installSteamClient(in wrappPath: URL) async throws {
        // Check cache first
        if try cacheManager.restoreCache(stage: .steamClientInstalled, to: wrappPath) != nil {
            return
        }

        await bus.publishWrappBuild(.progress(.installingGame(substep: "Installing Steam")))

        // Stop wine server first
        let wine = WineEnvironment(appPath: wrappPath)
        _ = wine.stopWineserver()

        // Valve's installer, run silently. Not `winetricks steam`: that first
        // installs Microsoft's core fonts (for a Wine bug that crashed Steam's
        // web helper without them), which needs cabextract, which isn't
        // bundled — and Steam signs in fine under the bundled Wine without them.
        let installer = try await steamInstaller()
        try await wine.runWine(executable: "wine", arguments: [installer.path, "/S"], timeout: 300)

        // Save to cache
        try cacheManager.saveCache(wrappPath: wrappPath, stage: .steamClientInstalled)
    }

    // MARK: - Finalization

    /// Sequence the tail of every build: sign → ask about success reports
    /// (once ever) → resolve output → save →
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
        // A build cancelled during a step that doesn't stop for it (a copy,
        // say) stops here, before anything is saved.
        try Task.checkCancellation()
        // Sign before moving so failures trigger the builder's cleanup
        try await signWrapp(at: wrappPath)
        await bus.publishWrappBuild(.signed(wrappPath: wrappPath))

        // Asked once ever, before the save panel, while the build has just worked.
        await input.askAboutSuccessReports()
        try Task.checkCancellation()
        await bus.publishWrappBuild(.progress(.savingApp(substep: nil)))
        let outputDir = try await input.getOutputPath(gameName: gameInfo.title)
        try Task.checkCancellation()
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
    func signWrapp(at path: URL) async throws {
        logger.notice("Signing wrapp...")

        let codesignPath = "/usr/bin/codesign"
        let arguments = ["--force", "--sign", "-", "--verbose=2", path.path]
        let sign = try await Process.output(of: codesignPath, arguments)

        if sign.succeeded {
            logger.notice("✅ Wrapp signed successfully")
        } else {
            let command = "\(codesignPath) \(arguments.joined(separator: " "))"
            logger.error("⚠️ Code signing failed: \(sign.errorOutput)")
            logger.notice("   Command: \(command)")
            throw WrappError.signingFailed(sign.errorOutput)
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

        // Name the destination in any failure: Foundation's own message names
        // the temp bundle ("NancyDrew-<UUID>.app couldn't be moved…"), which
        // says nothing about where it was going.
        // A copy, not a rename, when the destination is on another volume.
        do {
            try await Blocking.run {
                // Remove existing if present
                if FileManager.default.fileExists(atPath: finalPath.path) {
                    try FileManager.default.removeItem(at: finalPath)
                }
                try FileManager.default.moveItem(at: wrappPath, to: finalPath)
            }
        } catch {
            logger.error("Couldn't save the wrapp to \(finalPath.path): \(ErrorChain.describe(error))")
            throw WrappBuildError.saveFailed(destination: finalPath.path, reason: error.localizedDescription)
        }

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
    func removeTempWrapp(_ path: URL) async {
        wrappsLock.lock()
        temporaryWrapps.remove(path)
        wrappsLock.unlock()

        guard fileManager.fileExists(atPath: path.path) else { return }

        if DebugSettings.shared.debugMode {
            logger.notice("🐛 DEBUG: Keeping temp wrapp for inspection: \(path.path)")
            return
        }

        // A build that failed partway can leave its Wine session running,
        // and once the wrapp is gone so is the wineserver that could stop it:
        // the processes then run on, one of them using most of a core.
        let wine = WineEnvironment(appPath: path)
        if fileManager.fileExists(atPath: wine.wineBinDir.appendingPathComponent("wineserver").path) {
            let status = await Blocking.run { wine.stopWineserver() }
            if status != 0 {
                logger.debug("wineserver -k for \(path.lastPathComponent) exited \(status) (no session running)")
            }
        }

        do {
            try await Blocking.run { try Self.removeWrappDirectory(path) }
            logger.notice("🧹 Removed temp wrapp: \(path.lastPathComponent)")
        } catch {
            logger.warning("   ⚠️ Failed to remove \(path.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Delete a wrapp, read-only parts and all. A wrapp built from discs
    /// before they were made writable on copy holds read-only directories that
    /// `removeItem` can't empty, so on failure give the owner write permission
    /// throughout and try again.
    private nonisolated static func removeWrappDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: url)
        } catch {
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+w", url.path]
            chmod.standardOutput = FileHandle.nullDevice
            chmod.standardError = FileHandle.nullDevice
            try chmod.run()
            chmod.waitUntilExit()
            try fileManager.removeItem(at: url)
        }
    }

    /// Clean up all tracked temporary wrapps (app termination / crash paths).
    /// Remove temp wrapps an earlier run left behind: one that was killed,
    /// or crashed, never got to its cleanup, and each holds a whole Wine
    /// prefix. Only those untouched for `olderThan`, so another build in
    /// progress keeps its own; none in debug mode, which keeps them on purpose.
    func sweepStaleTemporaryWrapps(olderThan age: TimeInterval = 6 * 60 * 60) {
        guard !DebugSettings.shared.debugMode else { return }
        let tempDir = fileManager.temporaryDirectory
        let candidates = (try? fileManager.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for wrapp in candidates where wrapp.lastPathComponent.hasPrefix("NancyDrew-") && wrapp.pathExtension == "app" {
            guard let modified = (try? wrapp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified < cutoff else { continue }
            let size = DirectorySize.measure(wrapp)
            do {
                try Self.removeWrappDirectory(wrapp)
                logger.notice("🧹 Removed a temp wrapp left by an earlier run: \(wrapp.lastPathComponent) (\(size.description), last changed \(modified))")
            } catch {
                logger.warning("Can't remove the stale temp wrapp \(wrapp.path): \(error.localizedDescription)")
            }
        }
    }

    func cleanupTemporaryWrapps() {
        wrappsLock.lock()
        let wrapps = Array(temporaryWrapps)
        temporaryWrapps.removeAll()
        wrappsLock.unlock()

        guard !wrapps.isEmpty else { return }

        // Skip deletion in debug mode
        if DebugSettings.shared.debugMode {
            logger.notice("🐛 DEBUG: Keeping \(wrapps.count) temporary wrapp(s) for inspection:")
            for wrapp in wrapps where fileManager.fileExists(atPath: wrapp.path) {
                logger.notice("   \(wrapp.path)")
            }
            return
        }

        logger.notice("🧹 Cleaning up \(wrapps.count) temporary wrapp(s)...")
        for wrapp in wrapps {
            do {
                if fileManager.fileExists(atPath: wrapp.path) {
                    logger.notice("   Removing: \(wrapp.path)")
                    try Self.removeWrappDirectory(wrapp)
                }
            } catch {
                logger.warning("   ⚠️ Failed to remove \(wrapp.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Launch

    /// Launch the finished wrapp (headless automation support).
    func launchGame(at appPath: URL, with arguments: [String]) async throws {
        let launchDesc = appPath.path + (arguments.isEmpty ? "" : " \(arguments.joined(separator: " "))")
        logger.notice("Launching: \(launchDesc)")

        // Build arguments: open <app-path> --args <app-arguments>
        var openArgs = [appPath.path]
        if !arguments.isEmpty {
            openArgs.append("--args")
            openArgs.append(contentsOf: arguments)
        }
        let open = try await Process.output(of: "/usr/bin/open", openArgs)

        if open.succeeded {
            logger.notice("Game launched successfully")
        } else {
            throw NSError(domain: "GameLaunch", code: Int(open.status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch game: open command exited with status \(open.status)"
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
    /// Files in the template have lost the code signatures they keep in
    /// extended attributes (`verifyTemplateSignatures`).
    case templateSignaturesLost(String)

    var errorDescription: String? {
        switch self {
        case .cachedGameMismatch:
            return "Cached wrapp belongs to a different game"
        case .invalidInfoPlist:
            return "Part of Second Chance is damaged (the game app template). Download Second Chance again and try once more."
        case .wineNotFound:
            return "Part of Second Chance is missing (Wine). Download Second Chance again and try once more."
        case .templateNotFound(let message):
            return message
        case .copyFailed(let message, _, _):
            return message
        case .signingFailed(let message):
            return "Code signing failed: \(message)"
        case .templateSignaturesLost:
            return "Second Chance's copy of the game template is damaged: some of its files have lost their code signatures, "
                + "so no game could be signed. This happens when Second Chance is copied with a tool that leaves out "
                + "extended attributes. Download Second Chance again, or copy it with Finder."
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
