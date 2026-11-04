//
//  Configuration.swift
//  WrappTemplate
//
//  Configuration management for Nancy Drew game wrappers

import Foundation
import GameCatalog
import Logging
import SecondChanceKit
import AppKit

private nonisolated let configLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Configuration")

// MARK: - Game Configuration

struct GameConfig {
    let appPath: URL
    let winePrefix: URL
    let gameExePath: String
    let gameInstallerDir: String
    /// The modules the wrapp runs (`RuntimeModules`).
    let composition: Composition
    /// How the game starts, as its build recorded it (or its legacy settings
    /// mean, for a wrapp built before).
    var launch: RecordedLaunch
    /// Whether the build recorded the launch, rather than the wrapp making
    /// one from its legacy settings.
    var launchRecorded = false
    let steamGameId: String?
    let gameTitle: String
    let gameSlug: String
    /// Where the game came from: `disk`, `her-download` or `steam`, or
    /// `unknown` for a wrapp built before it was recorded.
    let gameSource: String
    let bundleId: String
    /// Where the player's saves, and the game's settings that live beside
    /// them, are kept: the volume the game saves in
    /// (`Application Support/<bundle id>/volumes/<volume>/`), or for a wrapp
    /// built before volumes, its folder in Application Support.
    let appSupportPath: URL
    /// Where Second Chance's own settings for this wrapp are kept (the save
    /// warning's "don't show again").
    let settingsPath: URL
    /// ScummVM's settings for this game.
    let scummvmConfigPath: URL
    /// For a game installed through Big Fish's Game Manager, its
    /// `LaunchGame.bfg` (from the root of C:, as `gameExePath`), which Big
    /// Fish's `bfgprocess.exe` is given to start it (docs/big-fish.md).
    var bigFishLaunchFile: String?
    /// The edition's Big Fish SKU (`F2435T1L1`).
    var bigFishSKU: String?
    /// A Big Fish free trial (only the integration tests build them): the
    /// wrapp starts it with the Game Manager's Play Now, the only way a trial
    /// starts.
    var bigFishTrial = false
    /// What every Wine program of the game's session runs with
    /// (`Wine.sessionVariables`): an owned Big Fish game's in-process
    /// helpers (`BigFishRuntime.sessionVariables`), as a Windows service
    /// starts it. Empty for every other game.
    var wineSessionVariables: [String: String] = [:]

    /// The wrapp's Wine, running in the prefix the game runs in.
    nonisolated var wine: Wine {
        var wine = Wine(wrapp: appPath, prefix: winePrefix)
        wine.sessionVariables = wineSessionVariables
        return wine
    }

    /// Whether this launch has a program to fall back to when it fails
    /// (`LAUNCH --fallback`): a DRM-free game the person chose to launch
    /// through Steam, whose files Wine runs just as well.
    var hasFallback: Bool { launch.fallback != nil }

    /// This configuration, launching the fallback rather than the program
    /// (`--launch-fallback`): run without the main launch's launcher, as
    /// its module's, with the main launch's options.
    func withFallback() -> GameConfig {
        guard let fallback = launch.fallback else { return self }
        var launch = launch
        launch.program = fallback
        launch.fallback = nil
        launch.options["steam.exe"] = nil
        return GameConfig(
            appPath: appPath, winePrefix: winePrefix, gameExePath: drivePath(of: launch) ?? gameExePath,
            gameInstallerDir: gameInstallerDir, composition: Composition(launcher: launch.launcher() ?? .wine), launch: launch,
            launchRecorded: launchRecorded, steamGameId: nil,
            gameTitle: gameTitle, gameSlug: gameSlug,
            gameSource: gameSource, bundleId: bundleId, appSupportPath: appSupportPath, settingsPath: settingsPath,
            scummvmConfigPath: scummvmConfigPath
        )
    }
}

// MARK: - Plist Reading

func readPlist(at path: URL, key: String) -> String? {
    guard let data = try? Data(contentsOf: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return nil
    }

    // Support nested keys using dot notation (e.g., "Parent.Child")
    let keys = key.split(separator: ".").map(String.init)
    var current: Any? = plist

    for key in keys {
        guard let dict = current as? [String: Any] else {
            return nil
        }
        current = dict[key]
    }

    // Convert result to string
    if let string = current as? String {
        return string
    } else if let number = current as? NSNumber {
        return number.stringValue
    } else if let bool = current as? Bool {
        return bool ? "true" : "false"
    }

    return nil
}

func getWinePrefix(appPath: URL, bundleId: String) -> URL {
    let originalPrefixPath = WrappLayout(app: appPath).prefix
    let fileManager = FileManager.default

    // Test if prefix is writable
    let testFile = originalPrefixPath.appendingPathComponent(".write_test")
    let isPrefixReadOnly = !fileManager.isWritableFile(atPath: originalPrefixPath.path) ||
                           !fileManager.createFile(atPath: testFile.path, contents: Data(), attributes: nil)

    if !isPrefixReadOnly {
        // Clean up test file and return original prefix
        try? fileManager.removeItem(at: testFile)
        return originalPrefixPath
    }

    // Prefix is read-only, set up cached copy
    configLogger.notice("[Wine] Prefix is read-only, copying to cache directory...")

    let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    var cachedPrefixPath = cacheDir
        .appendingPathComponent(bundleId)
        .appendingPathComponent("prefix")

    // The copy is kept from one launch to the next, with what the game and
    // Wine changed in it, for as long as it is a copy of this same prefix:
    // where it came from, and when that prefix's registry last changed (a
    // rebuilt or updated wrapp changes it).
    let stampFile = cachedPrefixPath.appendingPathComponent(".copied-from")
    let systemReg = originalPrefixPath.appendingPathComponent("system.reg")
    let modified = (try? fileManager.attributesOfItem(atPath: systemReg.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let stamp = "\(originalPrefixPath.path)\n\(modified)\n"
    if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp {
        configLogger.notice("[Wine] Prefix is read-only; using its copy from an earlier launch")
        return cachedPrefixPath
    }

    // Try to remove existing cache if present
    if fileManager.fileExists(atPath: cachedPrefixPath.path) {
        configLogger.notice("[Wine] Removing existing cached prefix...")
        do {
            try fileManager.removeItem(at: cachedPrefixPath)
        } catch {
            // If removal fails (e.g., permissions issues), use a new path with timestamp
            configLogger.notice("[Wine] Could not remove existing cache, using timestamped path instead")
            let timestamp = Int(Date().timeIntervalSince1970)
            cachedPrefixPath = cacheDir
                .appendingPathComponent(bundleId)
                .appendingPathComponent("prefix-\(timestamp)")
        }
    }

    // Create cache directory
    try? fileManager.createDirectory(at: cachedPrefixPath, withIntermediateDirectories: true)

    // Copy all contents except drive_c
    do {
        let prefixContents = try fileManager.contentsOfDirectory(atPath: originalPrefixPath.path)

        for item in prefixContents {
            if item == "drive_c" {
                continue  // Skip drive_c for now, will handle separately
            }

            let sourcePath = originalPrefixPath.appendingPathComponent(item)
            let destPath = cachedPrefixPath.appendingPathComponent(item)

            // Use cp -R to copy without preserving BSD flags (uchg)
            // Note: Not using -p flag so it won't preserve flags
            let cpProcess = Process()
            cpProcess.executableURL = URL(fileURLWithPath: "/bin/cp")
            cpProcess.arguments = ["-R", sourcePath.path, destPath.path]
            try cpProcess.run()
            cpProcess.waitUntilExit()
        }

        configLogger.notice("[Wine] Copied prefix contents to cache (excluding drive_c)")

        // Recreate drive_c structure with selective copying/symlinking
        let originalDriveCPath = originalPrefixPath.appendingPathComponent("drive_c")
        let cachedDriveCPath = cachedPrefixPath.appendingPathComponent("drive_c")

        func recreateDriveCStructure(sourceDir: URL, destDir: URL) throws {
            // Create destination directory
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Get contents of source directory
            let contents = try fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])

            for sourceItem in contents {
                let destItem = destDir.appendingPathComponent(sourceItem.lastPathComponent)

                // Check if it's a symlink
                let resourceValues = try sourceItem.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])

                if resourceValues.isSymbolicLink == true {
                    // Copy symlinks as-is
                    let symlinkDest = try fileManager.destinationOfSymbolicLink(atPath: sourceItem.path)
                    try fileManager.createSymbolicLink(atPath: destItem.path, withDestinationPath: symlinkDest)

                } else if resourceValues.isDirectory == true {
                    // Recursively handle directories
                    try recreateDriveCStructure(sourceDir: sourceItem, destDir: destItem)

                } else {
                    // Handle regular files based on size
                    let fileSize = resourceValues.fileSize ?? 0

                    if fileSize < 10_000 {
                        // Copy small files (< 10KB)
                        try fileManager.copyItem(at: sourceItem, to: destItem)
                    } else {
                        // Create symlink for large files (>= 10KB)
                        try fileManager.createSymbolicLink(at: destItem, withDestinationURL: sourceItem)
                    }
                }
            }
        }

        try recreateDriveCStructure(sourceDir: originalDriveCPath, destDir: cachedDriveCPath)

        configLogger.notice("[Wine] Recreated drive_c structure with selective copying/symlinking")
        do {
            try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        } catch {
            configLogger.warning("[Wine] Couldn't mark the prefix's copy, so the next launch copies it again: \(error.localizedDescription)")
        }

        return cachedPrefixPath

    } catch {
        configLogger.critical("⛔️ [Wine] Error setting up cached prefix: \(error)")
        configLogger.error("[Wine] Falling back to the read-only original prefix: Wine can't write its registry there, and a game that saves its settings in it will fail to")
        try? fileManager.removeItem(at: stampFile)
        return originalPrefixPath
    }
}

func loadConfig(customWinePrefix: URL? = nil) -> GameConfig? {
    // Get app path
    guard let executablePath = ProcessInfo.processInfo.arguments.first else {
        configLogger.critical("ERROR: Could not determine executable path")
        return nil
    }

    let executableURL = URL(fileURLWithPath: executablePath)
    let appPath = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    let layout = WrappLayout(app: appPath)
    let settings: WrappSettings
    do {
        settings = try WrappSettings(of: layout)
    } catch {
        configLogger.critical("ERROR: Could not read the game's settings from \(layout.settingsFile.path): \(error)")
        return nil
    }
    guard let gameTitle = readPlist(at: layout.infoPlist, key: "CFBundleName"),
          let bundleId = readPlist(at: layout.infoPlist, key: "CFBundleIdentifier") else {
        configLogger.critical("ERROR: Could not read the game's name and bundle identifier from Info.plist")
        return nil
    }

    let winePrefix = customWinePrefix ?? layout.prefix

    let files = userFiles(layout: layout, bundleId: bundleId)

    var config = GameConfig(
        appPath: appPath,
        winePrefix: winePrefix,
        gameExePath: settings.recordedLaunch.flatMap(drivePath(of:)) ?? settings.gameExePath,
        gameInstallerDir: settings.installerDir,
        composition: settings.composition,
        launch: settings.launch,
        launchRecorded: settings.recordedLaunch != nil,
        steamGameId: settings.recordedLaunch.flatMap(steamAppID(of:)) ?? settings.steamAppID,
        gameTitle: gameTitle,
        gameSlug: settings.gameSlug ?? "unknown",
        gameSource: settings.source?.rawValue ?? "unknown",
        bundleId: bundleId,
        appSupportPath: files.saves,
        settingsPath: files.settings,
        scummvmConfigPath: files.scummvmConfig,
        bigFishLaunchFile: settings.recordedLaunch.flatMap(bigFishLaunchFile(of:)) ?? settings.bigFishLaunchFile,
        bigFishSKU: settings.bigFishSKU,
        bigFishTrial: settings.bigFishTrial ?? false
    )
    config.wineSessionVariables = BigFishRuntime.sessionVariables(config)
    return config
}

/// A Wine or DOSBox launch's program as a path from the root of its C:
/// drive (`/Nancy Drew/Game.exe`), as the runtimes find it, or for Steam's
/// or Big Fish's launch the program it starts (`--steam.exe`,
/// `--big-fish.exe`); nil for another.
func drivePath(of launch: RecordedLaunch) -> String? {
    let program = launch.options["steam.exe"] ?? launch.options["big-fish.exe"] ?? launch.program
    for prefix in ["wine:C:", "dosbox:C:"] where program.hasPrefix(prefix) {
        return String(program.dropFirst(prefix.count))
    }
    return nil
}

/// The `.bfg` a Big Fish launch has Big Fish's DRM start, as a path from the
/// root of C: (`/Program Files (x86)/…/LaunchGame.bfg`).
func bigFishLaunchFile(of launch: RecordedLaunch) -> String? {
    let prefix = "big-fish:C:"
    return launch.program.hasPrefix(prefix) ? String(launch.program.dropFirst(prefix.count)) : nil
}

/// The Steam app a Steam launch starts (`steam://rungameid/<id>`).
func steamAppID(of launch: RecordedLaunch) -> String? {
    let prefix = "steam://rungameid/"
    return launch.program.hasPrefix(prefix) ? String(launch.program.dropFirst(prefix.count)) : nil
}

/// Where the wrapp keeps what's the person's, moving it in first from the
/// folders the program's wrapps kept under former bundle ids
/// (`UserFilesMove`, docs/wrapp-launch.md#user-files).
/// `SECOND_CHANCE_APP_SUPPORT_DIR` names a folder in place of Application
/// Support: WrappPuppeteer gives each test launch an empty one, so a test
/// neither reads nor changes the player's saves and settings -- a game set
/// to play in a window there fails the fullscreen check.
func userFiles(layout: WrappLayout, bundleId: String) -> (saves: URL, settings: URL, scummvmConfig: URL) {
    let fileManager = FileManager.default
    let underTest = ProcessInfo.processInfo.environment["SECOND_CHANCE_APP_SUPPORT_DIR"].map { !$0.isEmpty } ?? false
    let userFiles = UserFilesLayout(appSupport: UserFilesLayout.appSupport(), bundleID: bundleId)
    let lock: WrappLock?
    do {
        lock = try WrappLock(of: layout)
    } catch {
        configLogger.error("Couldn't read what the wrapp was built from (\(layout.lockFile.lastPathComponent)): \(error)")
        lock = nil
    }
    let preferences = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")

    // A program whose bundle declares no volumes (SkiFree keeps nothing)
    // still has the wrapp's layout: its settings in wrapp-settings/, and a
    // Wine program's Documents in the wine module's default volume.
    if let lock, lock.savesVolume == nil, lock.volumes == nil {
        let saves = userFiles.volume("wine-documents")
        try? fileManager.createDirectory(at: saves, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: userFiles.settings, withIntermediateDirectories: true)
        return (saves, userFiles.settings, userFiles.settings.appendingPathComponent("scummvm.ini"))
    }

    guard let lock, let savesVolume = lock.savesVolume else {
        // Built before volumes: everything loose in its folder, ScummVM's
        // settings in Preferences, as such a wrapp always had them.
        let folder = userFiles.folder
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let scummvmConfig = underTest ? folder.appendingPathComponent("scummvm.ini")
            : preferences.appendingPathComponent("\(bundleId).ini")
        return (folder, folder, scummvmConfig)
    }

    // Another copy of this game running, under either id, could be saving
    // through the folder being moved; this copy itself doesn't count.
    let isRunning: (String) -> Bool = { id in
        NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
    }
    let move = UserFilesMove(layout: userFiles, formerBundleIDs: lock.formerBundleIDs ?? [],
                             volumes: lock.volumes ?? [], linkVolume: savesVolume)
    let outcome = move.run(isRunning: isRunning)
    for line in outcome.log { configLogger.notice("[User files] \(line)") }

    let saves = userFiles.volume(savesVolume)
    try? fileManager.createDirectory(at: saves, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: userFiles.settings, withIntermediateDirectories: true)
    guard let settingsVolume = lock.scummvmSettingsVolume else {
        return (saves, userFiles.settings, userFiles.settings.appendingPathComponent("scummvm.ini"))
    }
    let scummvmConfig = userFiles.volume(settingsVolume).appendingPathComponent("scummvm.ini")
    try? fileManager.createDirectory(at: scummvmConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    // ScummVM's settings were kept in Preferences by the old id: moved in,
    // and left as a link, when nothing is there yet. Not under test.
    if !underTest, UserFilesMove.kind(of: scummvmConfig) == .missing {
        for former in lock.formerBundleIDs ?? [] {
            let old = preferences.appendingPathComponent("\(former).ini")
            guard UserFilesMove.kind(of: old) == .other, !isRunning(former) else { continue }
            do {
                try fileManager.moveItem(at: old, to: scummvmConfig)
                try fileManager.createSymbolicLink(at: old, withDestinationURL: scummvmConfig)
                configLogger.notice("[User files] Moved ScummVM's settings from \(old.lastPathComponent), and left a link")
            } catch {
                configLogger.error("[User files] Couldn't move ScummVM's settings from \(old.lastPathComponent): \(error)")
            }
            break
        }
    }
    return (saves, userFiles.settings, scummvmConfig)
}
