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
    private let engines: EngineStore
    let bus: EventBus<AppEvent>

    init(
        wineManager: WineManager = .shared,
        cacheManager: CacheManager = .shared,
        engines: EngineStore = WrappBuildHelper.standardEngines,
        bus: EventBus<AppEvent> = .app
    ) {
        self.wineManager = wineManager
        self.cacheManager = cacheManager
        self.engines = engines
        self.bus = bus
    }

    /// The engine store every build shares: this Mac's, fetched with the
    /// download source's downloader.
    nonisolated static let standardEngines = EngineStore(
        root: EngineStore.standardRoot(),
        preparer: EnginePreparer(downloader: DownloadWrappBuilder.standardDownloader())
    )

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

    /// A wrapp of the launcher alone (the template), with the engines the
    /// build needs from the engine store: Wine whenever the build runs a
    /// Windows program (`buildsWithWine`) or the game runs in it, and each
    /// engine `composition` runs. Wine's prefix is made, or a bare C: drive
    /// for a build without Wine. An engine the build used but the game
    /// doesn't is removed again by `cleanupUnusedEngine`.
    func createBaseWrapp(at path: URL, composition: Composition? = nil, buildsWithWine: Bool = true) async throws {
        guard let templatePath = Bundle.main.url(forResource: "WrappTemplate", withExtension: "app") else {
            throw WrappBuildError.templateDamaged("WrappTemplate.app not found in Second Chance.app bundle")
        }
        // Before the cache too: a cached base wrapp came from this template.
        try await verifyTemplateSignatures(templatePath)
        await bus.publishWrappBuild(.wrappStarted(path: path))
        let engines = try engineModules(composition: composition, buildsWithWine: buildsWithWine)

        // The development cache's base is only good for a build that wants
        // the same engines.
        if try cacheManager.restoreCache(stage: .base, to: path) != nil {
            let restored = EngineInstall.installed(in: path.appendingPathComponent("Contents")).map(\.module)
            if restored == engines.map(\.manifest.id).sorted() { return }
            logger.notice("The cached base wrapp has \(restored), not the engines this build wants: building it afresh")
            await Blocking.run { try? FileManager.default.removeItem(at: path) }
        }

        logger.notice("Creating the wrapp from the template, with \(engines.map(\.manifest.id).joined(separator: " and "))")
        await bus.publishWrappBuild(.progress(.settingUpWrapp(substep: nil)))
        do {
            try await copyTemplate(at: templatePath, to: path)
        } catch {
            logger.critical("❌ Failed to copy wrapp template: \(error.localizedDescription)")
            throw error
        }
        for module in engines {
            try await installEngine(module, into: path)
        }

        if engines.contains(where: { $0.manifest.id == ModuleID.wine.rawValue }) {
            try await wineManager.createWinePrefix(at: path, bus: bus)
        } else {
            try fileManager.createDirectory(at: WrappLayout(app: path).driveC, withIntermediateDirectories: true)
        }

        try cacheManager.saveCache(wrappPath: path, stage: .base)
    }

    /// The engine modules a build needs, Wine first: it is what the prefix
    /// is made with.
    private func engineModules(composition: Composition?, buildsWithWine: Bool) throws -> [ModuleFolder] {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
        var wanted: [ModuleID] = buildsWithWine ? [.wine] : []
        for module in composition?.modules ?? [] where !wanted.contains(module) { wanted.append(module) }
        return wanted.compactMap { id in modules.first { $0.manifest.id == id.rawValue && $0.manifest.package() != nil } }
    }

    /// Put `module`'s engine into the wrapp at `path`, from the store, which
    /// fetches and prepares it the first time a build on this Mac needs it.
    private func installEngine(_ module: ModuleFolder, into path: URL) async throws {
        let id = module.manifest.id
        let engine: EngineStore.Engine
        do {
            engine = try await engines.engine(module) { step in logger.notice("[Engine] \(step)") }
        } catch let error as DownloadError {
            logger.error("[Engine] Couldn't fetch \(id): \(error.description)")
            for failure in error.failures { logger.error("[Engine]   \(failure)") }
            throw WrappBuildError.engineUnavailable
        }
        logger.notice("[Engine] \(engine.prepared ? "Prepared" : "Using the stored") \(id) \(engine.version) (\(engine.hash.prefix(12))…)")
        try await Blocking.run { try EngineInstall.install(engine, into: path.appendingPathComponent("Contents")) }
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

    /// Remove from the wrapp each engine its composition doesn't run: Wine,
    /// for a ScummVM game whose installer ran under it.
    func cleanupUnusedEngine(at wrappPath: URL, composition: Composition) async throws {
        let contents = wrappPath.appendingPathComponent("Contents")
        for record in EngineInstall.installed(in: contents) where !composition.has(ModuleID(rawValue: record.module)) {
            try await Blocking.run {
                let before = DirectorySize.measure(contents)
                try EngineInstall.remove(module: record.module, from: contents)
                let freed = ByteCountFormatter.string(fromByteCount: before.bytes - DirectorySize.measure(contents).bytes, countStyle: .file)
                logger.notice("Removed \(record.module), which the game doesn't use: \(freed)")
            }
        }
    }

    /// The edition a build from `source` is, where the builder doesn't say:
    /// the disc's `cd`, Her's Windows download, Steam's or Big Fish's.
    nonisolated static func edition(of source: WrappSource) -> String {
        switch source {
        case .disk: "cd"
        case .herDownload: "her-windows"
        case .steam: "steam"
        case .bigFish: "big-fish"
        case .download: "download"
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
        steamLaunchMode: String? = nil,
        bigFishLaunchFile: String? = nil,
        bigFishSKU: String? = nil,
        bigFishTrial: Bool? = nil,
        configureINI: Bool = true,
        bundleID: String? = nil,
        launch: RecordedLaunch? = nil,
        icon: String? = nil
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

        // The program's bundle's id (`au.gare.callum.second-chance.program.nancy-drew.<slug>`),
        // which names where the wrapp keeps the person's files.
        let newBundleID = bundleID ?? WrappLock.wrappBundleID(program: gameInfo.programID)
        plist["CFBundleIdentifier"] = newBundleID
        plist["CFBundleName"] = gameInfo.appName
        plist["CFBundleDisplayName"] = gameInfo.appName
        plist["GameExePath"] = gameExePath
        plist["Program Name and Path"] = gameExePath
        // The icon the Wrappfile names (`ICON`), in place of the template's
        // generic one, which `CFBundleIconName` names in its asset catalog
        // and would win over the file.
        if let icon {
            guard let file = WrappLayout(app: wrappPath).location(icon), fileManager.fileExists(atPath: file.path),
                  file.deletingLastPathComponent().lastPathComponent == "Resources" else {
                throw WrappBuildError.buildRecipeProblem("ICON \(icon) isn't a file in the app's Resources/")
            }
            plist["CFBundleIconFile"] = file.lastPathComponent
            plist.removeValue(forKey: "CFBundleIconName")
        }
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
            bigFishLaunchFile: bigFishLaunchFile, bigFishSKU: bigFishSKU, bigFishTrial: bigFishTrial,
            recordedLaunch: launch
        )
        try settings.write(to: WrappLayout(app: wrappPath))
        logger.notice("Created AppSettings.plist with engine: \(settings.engine.rawValue)")

        // A build that ran Wine has a prefix with drives; one that didn't (a
        // download ScummVM runs) has a bare C: drive, and nothing to point.
        if fileManager.fileExists(atPath: WrappLayout(app: wrappPath).prefix.appendingPathComponent("dosdevices").path) {
            // Each volume the launch gives a drive (`VOLUME --wine.drive=A:`)
            // has one, standing in for the player's files until the wrapp
            // points it at them each time it starts; Documents, where the
            // saves volume is, leads where its drive does (WineDrives has
            // why). A build with no launch recorded (Steam's, Big Fish's)
            // gives the saves A:, as every wrapp's always were.
            let wine = Wine(wrapp: wrappPath)
            let volumes = launch.map { $0.volumes.filter { $0.options["wine.drive"] != nil } }
                ?? [RecordedLaunch.Volume(name: "wine-documents", location: "wine:C:/users/crossover/Documents", options: ["wine.drive": "A:"])]
            for volume in volumes {
                guard let drive = volume.options["wine.drive"]?.lowercased().first else { continue }
                if (try? wine.drives.target(of: drive)) == nil {
                    try wine.drives.mount("/tmp/second-chance-nancy-drew-\(UUID().uuidString)", as: drive)
                }
                guard volume.location == "wine:C:/users/crossover/Documents" else { continue }
                try? FileManager.default.removeItem(at: wine.documents)
                try FileManager.default.createSymbolicLink(atPath: wine.documents.path, withDestinationPath: try wine.drives.target(of: drive))
            }
        }

        // Configure game INI files for LCD mode and save path
        if configureINI {
            try configureGameINI(in: WrappLayout(app: wrappPath).onDriveC(gameExePath).deletingLastPathComponent())
        }
    }

    /// Configure game INI files
    /// Give every .ini in `gameDir` the nancy-drew module's settings
    /// (`DO nancy-drew.configure-ini`).
    /// cnc-ddraw, for a Wine game the catalogue says draws with DirectDraw,
    /// built by a source whose edition has no stage yet (Steam's, Big
    /// Fish's): the wine module's `cnc-ddraw` function's steps, which a
    /// bundle's stage runs itself (`DO wine.cnc-ddraw`), as the shared
    /// prefix no longer has it.
    func setUpCncDdraw(for gameInfo: GameInfo, in wrappPath: URL) async throws {
        guard gameInfo.graphics == .directDraw, gameInfo.gameEngine != .scummvm,
              let resources = Bundle.main.resourceURL else { return }
        let steps = try await Blocking.run {
            let modules = try ModuleLoader(root: resources.appendingPathComponent("Modules")).loadAll().get()
            return try BuildPlanner.functionSteps("wine", "cnc-ddraw", modules: modules)
        }
        for step in steps {
            try await WineSteps(bus: bus).run(step, wrappPath: wrappPath)
        }
    }

    /// The recorded launch's program is in the app, once the build has made
    /// it: a Wine or DOSBox program's file, a ScummVM game's folder. A
    /// launch that isn't a path in the app (`steam://`) isn't checked.
    nonisolated static func checkLaunchProgram(_ launch: RecordedLaunch, in wrappPath: URL) throws {
        // Steam's launch names the program Steam starts (`--steam.exe`).
        let program = launch.options["steam.exe"] ?? launch.program
        guard program.hasPrefix("wine:") || program.hasPrefix("dosbox:") || program.hasPrefix("scummvm:") else { return }
        // ScummVM's is a folder in the app (`scummvm:/SharedSupport/game/`).
        let place = program.hasPrefix("scummvm:") ? String(program.dropFirst("scummvm:".count)) : program
        guard let location = WrappLayout(app: wrappPath).location(place) else {
            throw WrappBuildError.buildRecipeProblem("LAUNCH \(program) isn't in the app")
        }
        guard FileManager.default.fileExists(atPath: location.path) else {
            logger.critical("❌ The build didn't make what LAUNCH runs, \(program) (\(location.path))")
            throw WrappBuildError.gameExecutableNotFound
        }
        logger.notice("✓ LAUNCH's program is there: \(program)")
    }

    /// Whether a step copies into the app itself, outside the prefix: a
    /// `COPY` to a bare `/…` path. Builders run these after the cached
    /// install layer, which holds the prefix alone.
    nonisolated static func isAppStep(_ step: PlannedStep) -> Bool {
        step.module == nil && step.instruction == "COPY" && step.arguments.last?.hasPrefix("/") == true
    }

    /// The plan's steps that copy into the app: a bundle's or module's file
    /// (the icon), an input's files as they are (a disc's data), or a folder
    /// of another stage's (a game's data, out of the prefix it was installed
    /// in). `input` gives each input's folder by name. Publishes the game's
    /// data as installed once one is copied.
    func runAppSteps(_ plan: BuildPlan, wrappPath: URL, gameInfo: GameInfo,
                     input: (String) async throws -> URL?) async throws {
        let layout = WrappLayout(app: wrappPath)
        var copiedData = false
        for step in plan.stages.flatMap(\.steps) where Self.isAppStep(step) {
            logger.debug("Plan step: \(step) (\(step.origin))")
            guard step.arguments.count == 2, let destination = layout.location(step.arguments[1]) else {
                throw WrappBuildError.buildRecipeProblem("\(step.origin): this build can't run \(step)")
            }
            let source: URL
            if step.option("from") == nil {
                guard let file = plan.file(step.arguments[0]) else {
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): the plan has no file \(step.arguments[0])")
                }
                try copyFile(file, to: destination)
                continue
            } else if let name = PlannedStep.input(in: step.option("from")) {
                guard let folder = try await input(name) else {
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): this build has no \(name)")
                }
                source = step.arguments[0] == "." ? folder : folder.appendingPathComponent(step.arguments[0])
            } else {
                guard let folder = layout.location(step.arguments[0]) else {
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): \(step.arguments[0]) has no place in the app")
                }
                source = folder
            }
            if !copiedData {
                await bus.publishWrappBuild(.progress(.installingGame(substep: nil)))
                await bus.publishWrappBuild(.engineRouted(composition: gameInfo.composition, gameInfo: gameInfo))
                copiedData = true
            }
            try await copyContents(of: source, into: destination)
            logger.notice("Copied \(step.arguments[0]) from \(step.option("from") ?? "") into \(step.arguments[1])")
        }
        if copiedData {
            await bus.publishWrappBuild(.gameExeDetected(path: "/SharedSupport/game", gameInfo: gameInfo))
        }
    }

    /// A bundle's or module's file copied into the app (`COPY <file> <dest>`):
    /// into `destination` when it names a folder (`…/`), as it otherwise.
    func copyFile(_ file: URL, to destination: URL) throws {
        let target = destination.hasDirectoryPath ? destination.appendingPathComponent(file.lastPathComponent) : destination
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: file, to: target)
    }

    /// What's in `folder` copied into `destination`, merged with what's there:
    /// a file of the same name is replaced, as a later disc's files are by
    /// an earlier's. Off the main thread, as a disc is hundreds of MB.
    func copyContents(of folder: URL, into destination: URL) async throws {
        try await Blocking.run {
            let files = FileManager.default
            func merge(_ from: URL, _ into: URL) throws {
                try files.createDirectory(at: into, withIntermediateDirectories: true)
                for name in try files.contentsOfDirectory(atPath: from.path) {
                    let source = from.appendingPathComponent(name), target = into.appendingPathComponent(name)
                    var isFolder: ObjCBool = false
                    files.fileExists(atPath: source.path, isDirectory: &isFolder)
                    var targetIsFolder: ObjCBool = false
                    let exists = files.fileExists(atPath: target.path, isDirectory: &targetIsFolder)
                    if isFolder.boolValue, exists, targetIsFolder.boolValue {
                        try merge(source, target)
                        continue
                    }
                    if exists { try files.removeItem(at: target) }
                    try files.copyItem(at: source, to: target)
                    // A disc's files are read-only; the app's copy needn't be,
                    // or a later disc couldn't replace one, nor the app be removed.
                    if let enumerator = files.enumerator(atPath: target.path) {
                        for case let inner as String in enumerator {
                            _ = chmod(target.appendingPathComponent(inner).path, isFolder.boolValue ? 0o755 : 0o644)
                        }
                    }
                    _ = chmod(target.path, isFolder.boolValue ? 0o755 : 0o644)
                }
            }
            try merge(folder.resolvingSymlinksInPath(), destination)
        }
    }

    /// Remove something the build made that the app needn't keep; a failure
    /// is only logged. Hundreds of MB, so off the main thread.
    func removeQuietly(_ url: URL, what: String) async {
        do {
            try await Blocking.run { try FileManager.default.removeItem(at: url) }
        } catch CocoaError.fileNoSuchFile {
        } catch {
            logger.warning("Couldn't remove \(what) at \(url.path): \(error)")
        }
    }

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
        steamLaunchMode: String? = nil,
        bigFishLaunchFile: String? = nil,
        bigFishSKU: String? = nil,
        bigFishTrial: Bool? = nil,
        configureINI: Bool = true,
        edition: String? = nil,
        updated: WrappLock.UpdateRecord? = nil,
        launch: RecordedLaunch? = nil,
        icon: String? = nil,
        input: WrappBuildInput
    ) async throws -> URL {
        // What it was built from, for updating it and for reports; its
        // bundle names the wrapp's bundle id. Checking the bundle runs ajv:
        // off the main thread.
        let edition = edition ?? Self.edition(of: source)
        let slug = gameInfo.id, lockComposition = composition ?? gameInfo.composition
        var lock = try await Blocking.run {
            try ShippedBundles.lock(forGame: slug, edition: edition, source: source, composition: lockComposition)
        }
        lock.updated = updated
        if let launch { try Self.checkLaunchProgram(launch, in: wrappPath) }
        try await configureWrapp(
            at: wrappPath, gameInfo: gameInfo, source: source, gameExePath: gameExePath, installerDir: installerDir,
            steamID: steamID, composition: composition, steamLaunchMode: steamLaunchMode,
            bigFishLaunchFile: bigFishLaunchFile, bigFishSKU: bigFishSKU, bigFishTrial: bigFishTrial,
            configureINI: configureINI, bundleID: lock.wrappBundleID, launch: launch, icon: icon
        )
        // A program whose launch has no Wine (a ScummVM game whose data is in
        // the app) keeps no prefix: what was built in one isn't the app's.
        if let launch, !(composition ?? gameInfo.composition).has(.wine), launch.launcher() != .wine {
            await removeQuietly(WrappLayout(app: wrappPath).prefix, what: "the Wine prefix, which the game doesn't use")
        }
        try lock.write(to: WrappLayout(app: wrappPath))
        logger.notice("Built from \(lock.summary)")
        moveUserFiles(for: lock)
        await bus.publishWrappBuild(.wrappConfigured(exePath: gameExePath, installerDir: installerDir, gameInfo: gameInfo))
        let finalPath = try await finalize(wrapp: wrappPath, gameInfo: gameInfo, input: input)
        unregisterTemporaryWrapp(wrappPath)
        return finalPath
    }

    /// Move the person's files from the folders the program's wrapps kept
    /// under former bundle ids into this wrapp's layout, as every launch
    /// does too (`UserFilesMove`); in the folder the environment names in
    /// place of Application Support under test, so a test never touches a
    /// player's files.
    func moveUserFiles(for lock: WrappLock) {
        guard let saves = lock.savesVolume, let former = lock.formerBundleIDs, !former.isEmpty else { return }
        // A build under test moves files only in the folder it was given.
        guard !TestHost.isRunning || ProcessInfo.processInfo.environment["SECOND_CHANCE_APP_SUPPORT_DIR"] != nil else {
            logger.notice("[User files] Not moving anything: a build under test has no SECOND_CHANCE_APP_SUPPORT_DIR")
            return
        }
        let move = UserFilesMove(
            layout: UserFilesLayout(appSupport: UserFilesLayout.appSupport(), bundleID: lock.wrappBundleID),
            formerBundleIDs: former, volumes: lock.volumes ?? [], linkVolume: saves
        )
        let outcome = move.run(isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        for line in outcome.log { logger.notice("[User files] \(line)") }
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
