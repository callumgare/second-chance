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
import Synchronization
import Logging
import AppKit
import SecondChanceKit
import GameCatalog
import WrappBuilder

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

    /// Copy the template to `destination` with `cp`, which keeps its
    /// symlinks as links (FileManager's copy works around a VirtualBuddy
    /// shared-folder symlink problem less well) and its extended attributes,
    /// where the template's files keep their code signatures.
    ///
    /// `-c` clones each file (APFS `clonefile`) rather than copying its
    /// bytes, which makes the copy near instant and takes no space until a
    /// file changes. On a volume that can't clone, the copy is made in full.
    private func copyTemplate(at source: URL, to destination: URL) async throws {
        let executable = "/bin/cp"
        let clone = try await Process.output(of: executable, ["-ac", source.path, destination.path])
        if clone.succeeded { return }
        logger.notice("Couldn't clone the template (\(clone.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))); copying it in full")
        await Blocking.run { try? FileManager.default.removeItem(at: destination) }

        let arguments = ["-a", source.path, destination.path]
        let copy = try await Process.output(of: executable, arguments)
        if !copy.succeeded {
            let command = formatShellCommand(executable: executable, arguments: arguments)
            logger.notice("   Command: \(command)")
            logger.notice("   Output: \(copy.errorOutput)")
            if copy.errorOutput.contains("No space left on device") {
                throw WrappBuildError.notEnoughSpace(needed: nil, available: nil)
            }
            throw WrappBuildError.copyFailed("\(command): \(copy.errorOutput)")
        }
    }

    /// Create a base wrapp with both Wine and ScummVM support.
    func createBaseWrapp(at path: URL) async throws {
        // Find the pre-built unified template
        guard let templatePath = Bundle.main.url(forResource: "WrappTemplate", withExtension: "app") else {
            throw WrappBuildError.templateDamaged("WrappTemplate.app not found in Second Chance.app bundle")
        }
        // Before the cache too: a cached base wrapp came from this template.
        try await verifyTemplateSignatures(templatePath)
        await bus.publishWrappBuild(.wrappStarted(path: path))

        // Check cache first
        if try cacheManager.restoreCache(stage: .base, to: path) != nil {
            return
        }

        logger.notice("Creating unified wrapp with both Wine and ScummVM support...")
        await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))

        // Copy the entire template (includes both Wine and ScummVM)
        do {
            try await copyTemplate(at: templatePath, to: path)
        } catch {
            logger.critical("❌ Failed to copy wrapp template: \(error.localizedDescription)")
            throw error
        }

        // Create Wine prefix (ScummVM doesn't need initialization)
        try await wineManager.createWinePrefix(at: path, bus: bus)

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
            throw WrappBuildError.templateSignaturesLost(detail)
        }
        logger.warning("codesign --verify reports a problem with the wrapp template, carrying on: \(detail)")
    }

    /// Remove from the wrapp the files of each module its composition
    /// doesn't run (`BuildModule.templateFiles`).
    func cleanupUnusedEngine(at wrappPath: URL, composition: Composition) async throws {
        logger.notice("Cleaning up unused game engine from wrapp...")

        let resourcesPath = WrappLayout(app: wrappPath).resources
        for (module, list) in BuildModules.unusedTemplateFiles(for: composition) {
            try await removeEngineFiles(listedIn: resourcesPath.appendingPathComponent(list),
                                        engine: module.rawValue, from: wrappPath)
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

    /// The edition a build from `source` is, where the builder doesn't say:
    /// the disc's `cd`, Her's Windows download, Steam's or Big Fish's.
    static func edition(of source: WrappSource) -> String {
        switch source {
        case .disk: "cd"
        case .herDownload: "her-windows"
        case .steam: "steam"
        case .bigFish: "big-fish"
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
        composition: Composition? = nil,
        steamLaunchMode: GameInfo.SteamLaunchMode? = nil,
        bigFishLaunchFile: String? = nil,
        bigFishSKU: String? = nil,
        bigFishTrial: Bool? = nil,
        configureINI: Bool = true
    ) async throws {
        await bus.publishWrappBuild(.progress(.configuringWrapp(substep: String(localized: "Adjusting the game's settings"))))

        let infoPlistPath = WrappLayout(app: wrappPath).infoPlist

        // Update Info.plist
        guard let plistData = try? Data(contentsOf: infoPlistPath),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw WrappBuildError.templateDamaged("its Info.plist has no WrappTemplate bundle identifier")
        }

        // Update bundle identifier by replacing WrappTemplate with game ID
        guard let currentBundleID = plist["CFBundleIdentifier"] as? String else {
            throw WrappBuildError.templateDamaged("its Info.plist has no WrappTemplate bundle identifier")
        }

        guard currentBundleID.contains("WrappTemplate") else {
            throw WrappBuildError.templateDamaged("its Info.plist has no WrappTemplate bundle identifier")
        }

        let newBundleID = currentBundleID.replacingOccurrences(of: "WrappTemplate", with: "nancy-drew." + gameInfo.id)
        plist["CFBundleIdentifier"] = newBundleID
        plist["CFBundleName"] = gameInfo.appName
        plist["CFBundleDisplayName"] = gameInfo.appName
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

        // What the wrapp reads about its game when it starts. Its settings
        // still name the composition by its engine, as every wrapp's have.
        let composition = composition ?? gameInfo.composition
        guard let engine = composition.legacyEngine else { throw WrappBuildError.unsupportedEngine }
        let settings = WrappSettings(
            gameExePath: gameExePath, engine: engine, gameSlug: gameInfo.id,
            source: source, installerDir: installerDir, steamAppID: steamID, steamLaunchMode: steamLaunchMode,
            bigFishLaunchFile: bigFishLaunchFile, bigFishSKU: bigFishSKU, bigFishTrial: bigFishTrial
        )
        try settings.write(to: WrappLayout(app: wrappPath))
        logger.notice("Created AppSettings.plist with engine: \(settings.engine.rawValue)")

        // Documents leads where the A: drive does (WineDrives has why). The
        // wrapp points both at the player's saves each time it starts.
        let wine = Wine(wrapp: wrappPath)
        try? FileManager.default.removeItem(at: wine.documents)
        try FileManager.default.createSymbolicLink(
            atPath: wine.documents.path,
            withDestinationPath: try wine.drives.target(of: "a")
        )

        // Configure game INI files for LCD mode and save path
        if configureINI {
            try configureGameINI(in: WrappLayout(app: wrappPath).onDriveC(gameExePath).deletingLastPathComponent())
        }
    }

    /// Configure game INI files
    /// Give every .ini in `gameDir` the nancy-drew module's settings
    /// (`DO nancy-drew.configure-ini`).
    func configureGameINI(in gameDir: URL) throws {
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
        let settings = try NancyDrewModule.iniSettings()

        for iniFile in iniFiles {
            logger.notice("  Processing: \(iniFile.lastPathComponent)")

            // Written back in the encoding it came in: the game reads it.
            guard let (originalContent, encoding) = TextFile.read(iniFile) else {
                logger.warning("    ⚠️ Failed to read file")
                continue
            }

            var content = originalContent
            var modified = false

            // The nancy-drew module's settings (Modules/nancy-drew/ini.yaml):
            // LCD mode, and saves in Documents.
            for replacement in settings.replace ?? [] {
                if content.contains(replacement.from) {
                    content = content.replacingOccurrences(of: replacement.from, with: replacement.to)
                    logger.notice("    ✅ Set \(replacement.to)")
                    modified = true
                } else if let already = replacement.already, content.contains(already) {
                    logger.notice("    ℹ️ \(already) already")
                } else {
                    logger.notice("    ℹ️ No \(replacement.from) setting found")
                }
            }
            for setting in settings.set ?? [] {
                let line = "\(setting.key)=\(setting.value)"
                let pattern = try Regex("\(setting.key)=.*")
                if let match = content.firstMatch(of: pattern) {
                    let oldValue = String(content[match.range])
                    content = content.replacing(pattern) { _ in line }
                    logger.notice("    ✅ Updated \(setting.key)")
                    logger.notice("       Old: \(oldValue)")
                    logger.notice("       New: \(line)")
                    modified = true
                } else {
                    logger.notice("    ℹ️ No \(setting.key) setting found")
                }
            }

            // Write back if modified
            if modified {
                do {
                    try content.write(to: iniFile, atomically: true, encoding: encoding)
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

        await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: String(localized: "Installing Steam"))))

        let wine = Wine(wrapp: wrappPath)
        await wine.server.stop()

        // Valve's installer, run silently. Not `winetricks steam`: that first
        // installs Microsoft's core fonts (for a Wine bug that crashed Steam's
        // web helper without them), which needs cabextract, which isn't
        // bundled — and Steam signs in fine under the bundled Wine without them.
        let installer = try await steamInstaller()
        do {
            // It's run from the cache, which Wine sees only while its folder is lent.
            try wine.drives.lend(installer.deletingLastPathComponent())
            defer { wine.drives.takeBack() }
            try await wine.run(.program(installer.path, ["/S"]), timeout: 300)
        }

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
        // The template keeps the quarantine of the download Second Chance
        // came in (`cp -a` copies it), and macOS runs a quarantined wrapp
        // translocated: read-only, where Steam can't run or sign in.
        await Blocking.run { AppMover.removeQuarantine(from: wrappPath) }
        // Sign before moving so failures trigger the builder's cleanup
        try await signWrapp(at: wrappPath)
        await bus.publishWrappBuild(.signed(wrappPath: wrappPath))

        // Asked once ever, before the save panel, while the build has just worked.
        await input.askAboutSuccessReports()
        try Task.checkCancellation()
        await bus.publishWrappBuild(.progress(.savingApp(substep: nil)))
        let finalPath = try await input.getSaveLocation(for: gameInfo)
        try Task.checkCancellation()
        try await saveWrapp(from: wrappPath, to: finalPath)

        await input.onWrappBuildComplete(finalPath)
        await bus.publishWrappBuild(.completed(wrappPath: finalPath))

        return finalPath
    }

    /// The tail every builder ends with: configure the wrapp, publish that,
    /// then sign and save it (`finalize`), after which it is no longer
    /// temporary. One place, so no builder can drop one of its events.
    func completeBuild(
        wrapp wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource,
        gameExePath: String,
        installerDir: String,
        steamID: String? = nil,
        composition: Composition? = nil,
        steamLaunchMode: GameInfo.SteamLaunchMode? = nil,
        bigFishLaunchFile: String? = nil,
        bigFishSKU: String? = nil,
        bigFishTrial: Bool? = nil,
        configureINI: Bool = true,
        edition: String? = nil,
        input: WrappBuildInput
    ) async throws -> URL {
        try await configureWrapp(
            at: wrappPath, gameInfo: gameInfo, source: source, gameExePath: gameExePath, installerDir: installerDir,
            steamID: steamID, composition: composition, steamLaunchMode: steamLaunchMode,
            bigFishLaunchFile: bigFishLaunchFile, bigFishSKU: bigFishSKU, bigFishTrial: bigFishTrial,
            configureINI: configureINI
        )
        // What it was built from, for updating it and for reports.
        let edition = edition ?? Self.edition(of: source)
        // Checking the bundle runs ajv: off the main thread.
        let slug = gameInfo.id, composition = composition ?? gameInfo.composition
        let lock = try await Blocking.run {
            try ShippedBundles.lock(forGame: slug, edition: edition, source: source, composition: composition)
        }
        try lock.write(to: WrappLayout(app: wrappPath))
        logger.notice("Built from \(lock.summary)")
        await bus.publishWrappBuild(.wrappConfigured(exePath: gameExePath, installerDir: installerDir, gameInfo: gameInfo))
        let finalPath = try await finalize(wrapp: wrappPath, gameInfo: gameInfo, input: input)
        unregisterTemporaryWrapp(wrappPath)
        return finalPath
    }

    /// Launch the saved wrapp when the run asked for it (`LAUNCH_GAME`). The
    /// build has already succeeded, so a launch that fails is logged, not
    /// thrown: it would otherwise fail a build that had completed.
    func launchIfAsked(_ finalPath: URL, input: WrappBuildInput) async {
        let (shouldLaunch, args) = await input.shouldLaunchGame()
        guard shouldLaunch else { return }
        do {
            try await launchGame(at: finalPath, with: args)
        } catch {
            logger.error("The game was built, but launching it failed: \(ErrorChain.describe(error))")
        }
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
            throw WrappBuildError.signingFailed(sign.errorOutput)
        }
    }

    /// Move the finished wrapp to `finalPath`, replacing an app already
    /// there only once the new one is in place beside it.
    ///
    /// The new app is first moved in under a hidden name in the same folder
    /// (a copy, when the folder is on another volume, and the step most
    /// likely to fail), then swapped in with `replaceItemAt`. So a failure
    /// leaves any earlier copy of the game's app as it was, rather than
    /// having deleted it first.
    func saveWrapp(from wrappPath: URL, to finalPath: URL) async throws {
        logger.notice("Saving wrapp: \(finalPath.path)")
        let staged = finalPath.deletingLastPathComponent()
            .appendingPathComponent(".\(finalPath.lastPathComponent).saving-\(UUID().uuidString)")

        // Name the destination in any failure: Foundation's own message names
        // the temp bundle ("NancyDrew-<UUID>.app couldn't be moved…"), which
        // says nothing about where it was going.
        do {
            try await Blocking.run {
                let fileManager = FileManager.default
                do {
                    try fileManager.moveItem(at: wrappPath, to: staged)
                    if fileManager.fileExists(atPath: finalPath.path) {
                        _ = try fileManager.replaceItemAt(finalPath, withItemAt: staged)
                    } else {
                        try fileManager.moveItem(at: staged, to: finalPath)
                    }
                } catch {
                    if fileManager.fileExists(atPath: staged.path) {
                        do {
                            try fileManager.removeItem(at: staged)
                        } catch {
                            logger.warning("Couldn't remove the half-saved app at \(staged.path): \(error.localizedDescription)")
                        }
                    }
                    throw error
                }
            }
        } catch {
            logger.error("Couldn't save the wrapp to \(finalPath.path): \(ErrorChain.describe(error))")
            if ErrorChain.isOutOfSpace(error) {
                throw WrappBuildError.notEnoughSpace(needed: nil, available: nil)
            }
            throw WrappBuildError.saveFailed(destination: finalPath.path, reason: error.localizedDescription)
        }

        logger.notice("Wrapp saved: \(finalPath.path)")
    }

    // MARK: - Temp Wrapp Tracking (cleanup primitives)

    // Process-wide, not per helper: each build has a helper of its own (for
    // its own bus), and the app's quit cleans up through `.shared`.
    private struct Tracking {
        var wrapps: Set<URL> = []
        /// Run once no build has a temporary wrapp (`whenNoBuildIsRunning`).
        var whenNone: [@Sendable () -> Void] = []
    }
    private static let tracking = Mutex(Tracking())

    /// The file beside a temporary wrapp naming the process building it, so
    /// a sweep for ones left behind never takes a build that's still going.
    /// Beside it, not in it, where it would break the wrapp's signature.
    static func ownerFile(of wrapp: URL) -> URL {
        URL(fileURLWithPath: wrapp.path + ".owner")
    }

    /// Run `block` once no build has a temporary wrapp: at once if none
    /// does. For what mustn't happen mid-build, such as an update's relaunch.
    static func whenNoBuildIsRunning(_ block: @escaping @Sendable () -> Void) {
        let now = tracking.withLock { tracking in
            if tracking.wrapps.isEmpty { return true }
            tracking.whenNone.append(block)
            return false
        }
        if now { block() }
    }

    /// Stop tracking `path`, and run what was waiting for no builds if it
    /// was the last.
    private static func untrack(_ path: URL) {
        try? FileManager.default.removeItem(at: ownerFile(of: path))
        let waiting = tracking.withLock { tracking -> [@Sendable () -> Void] in
            tracking.wrapps.remove(path)
            guard tracking.wrapps.isEmpty else { return [] }
            defer { tracking.whenNone.removeAll() }
            return tracking.whenNone
        }
        waiting.forEach { $0() }
    }

    /// Fail at the start, in plain words, unless there looks to be room for
    /// a build from `source` (a disc, or a download) where temporary wrapps
    /// are made: `copies` of it (what is copied and unpacked, and the game
    /// it installs) plus the engine and prefix (`FreeSpace.buildOverhead`).
    /// An estimate, so it only catches a build sure to run out of space.
    func ensureRoomToBuild(from source: URL, copies: Int) async throws {
        guard let size = await Blocking.run({ FreeSpace.size(of: source) }) else { return }
        let needed = size * Int64(copies) + FreeSpace.buildOverhead
        try FreeSpace.ensure(needed, at: fileManager.temporaryDirectory)
    }

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
        Self.tracking.withLock { _ = $0.wrapps.insert(path) }
        do {
            try Data("\(getpid())".utf8).write(to: Self.ownerFile(of: path))
        } catch {
            logger.warning("Couldn't mark \(path.lastPathComponent) as this build's: \(error.localizedDescription)")
        }
    }

    /// Unregister a temporary wrapp (call after successful move/save)
    func unregisterTemporaryWrapp(_ path: URL) {
        Self.untrack(path)
    }

    /// Remove one tracked temp wrapp — a cleanup *primitive* the builder
    /// calls on its error path. No-op if already moved or removed.
    func removeTempWrapp(_ path: URL) async {
        defer { Self.untrack(path) }

        guard fileManager.fileExists(atPath: path.path) else { return }

        if DebugSettings.shared.debugMode {
            logger.notice("🐛 DEBUG: Keeping temp wrapp for inspection: \(path.path)")
            return
        }

        // A build that failed partway can leave its Wine session running,
        // and once the wrapp is gone so is the wineserver that could stop it:
        // the processes then run on, one of them using most of a core.
        await Wine(wrapp: path).server.stop()

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
            // A long build (Steam allows hours) barely touches the folder
            // itself: one whose builder is still running is still in use.
            if let owner = try? String(contentsOf: Self.ownerFile(of: wrapp), encoding: .utf8),
               let pid = pid_t(owner.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 || errno == EPERM {
                continue
            }
            let size = DirectorySize.measure(wrapp)
            do {
                try Self.removeWrappDirectory(wrapp)
                try? fileManager.removeItem(at: Self.ownerFile(of: wrapp))
                logger.notice("🧹 Removed a temp wrapp left by an earlier run: \(wrapp.lastPathComponent) (\(size.description), last changed \(modified))")
            } catch {
                logger.warning("Can't remove the stale temp wrapp \(wrapp.path): \(error.localizedDescription)")
            }
        }
    }

    /// Whether a build has a temporary wrapp that quitting would delete.
    static var hasTemporaryWrapps: Bool {
        tracking.withLock { !$0.wrapps.isEmpty }
    }

    /// End the Wine running in each temporary wrapp, before quitting deletes
    /// them: an installer partway through won't finish by itself, and Wine
    /// left running from a deleted folder would carry on with nothing to show
    /// for it. Each session is asked to stop first and forced only if it
    /// won't (`WineServer.shutDown`), all at once.
    static func endWineInTemporaryWrapps() async {
        let wrapps = tracking.withLock { Array($0.wrapps) }
        await withTaskGroup(of: Void.self) { group in
            for wrapp in wrapps {
                group.addTask {
                    let server = Wine(wrapp: wrapp).server
                    guard await server.isRunning else { return }
                    logger.notice("Ending Wine in \(wrapp.lastPathComponent) before quitting")
                    await server.shutDown(gracePeriod: 1)
                }
            }
        }
    }

    func cleanupTemporaryWrapps() {
        let wrapps = Self.tracking.withLock { tracking in
            defer { tracking.wrapps.removeAll() }
            return Array(tracking.wrapps)
        }

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
            try? fileManager.removeItem(at: Self.ownerFile(of: wrapp))
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
