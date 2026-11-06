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
    private let engines: EngineStore
    let bus: EventBus<AppEvent>
    /// Where each module's paths are in an app, and what older settings
    /// call them: the modules' kits Second Chance carries.
    let places: PathPlaces

    init(
        wineManager: WineManager = .shared,
        engines: EngineStore = WrappBuildHelper.standardEngines,
        bus: EventBus<AppEvent> = .app,
        places: PathPlaces = .shipped
    ) {
        self.wineManager = wineManager
        self.engines = engines
        self.bus = bus
        self.places = places
    }

    /// Where the engine store keeps what it keeps (Mac ROMs included).
    var engineRoot: URL { engines.root }

    /// The engine store every build shares: this Mac's, fetched with the
    /// download source's downloader.
    nonisolated static let standardEngines = EngineStore(
        root: EngineStore.standardRoot(),
        preparer: EnginePreparer(downloader: DownloadWrappBuilder.standardDownloader())
    )

    // MARK: - The template

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
    /// AppSettings.plist, remap the Documents symlink.
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
        bundleID: String? = nil,
        launch: RecordedLaunch? = nil,
        app: RecordedApp = RecordedApp()
    ) async throws {
        await bus.publishWrappBuild(.progress(.configuringWrapp(substep: String(localized: "Adjusting the game's settings"))))

        let infoPlistPath = WrappLayout(app: wrappPath).infoPlist

        // Update Info.plist
        guard let plistData = try? Data(contentsOf: infoPlistPath),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw WrappBuildError.templateDamaged("its Info.plist has no WrappTemplate bundle identifier")
        }

        // The template's id, or the one a step's `APP --default-id` wrote:
        // either way replaced by the caller's.
        guard plist["CFBundleIdentifier"] is String else {
            throw WrappBuildError.templateDamaged("its Info.plist has no bundle identifier")
        }

        // The program's bundle's id (`au.gare.callum.second-chance.program.nancy-drew.<slug>`),
        // which names where the wrapp keeps the person's files.
        // Second Chance always gives the id, so the Wrappfile's
        // `APP --default-id` never wins here (decision 25 of the builders plan).
        let newBundleID: String
        do {
            newBundleID = try app.id(given: bundleID ?? WrappLock.wrappBundleID(program: gameInfo.programID))
        } catch {
            // `id(given:)` throws only a PlanError.
            throw WrappBuildError.buildRecipeProblem(error.description)
        }
        plist["CFBundleIdentifier"] = newBundleID
        plist["CFBundleName"] = app.name ?? gameInfo.appName
        plist["CFBundleDisplayName"] = app.name ?? gameInfo.appName
        plist["GameExePath"] = gameExePath
        plist["Program Name and Path"] = gameExePath
        // The icon the Wrappfile names (`APP --icon`), in place of the template's
        // generic one, which `CFBundleIconName` names in its asset catalog
        // and would win over the file.
        if let icon = app.icon {
            guard let file = WrappLayout(app: wrappPath).location(icon, places: places), fileManager.fileExists(atPath: file.path),
                  file.deletingLastPathComponent().lastPathComponent == "Resources" else {
                throw WrappBuildError.buildRecipeProblem("APP --icon=\(icon) isn't a file in the app's Resources/")
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
        // still name the composition by its engine, as every wrapp's have,
        // when it has one; a composition with none (a program the core
        // starts) is read from the recorded launch, which it must have.
        let composition = composition ?? launch.map(Composition.init(launch:)) ?? gameInfo.composition
        let engine = composition.legacyEngine
        if engine == nil, launch == nil { throw WrappBuildError.unsupportedEngine }
        let settings = WrappSettings(
            gameExePath: gameExePath, engine: engine, gameSlug: gameInfo.id,
            source: source, installerDir: installerDir, steamAppID: steamID, steamLaunchMode: steamLaunchMode,
            bigFishLaunchFile: bigFishLaunchFile, bigFishSKU: bigFishSKU, bigFishTrial: bigFishTrial,
            recordedLaunch: launch
        )
        try settings.write(to: WrappLayout(app: wrappPath))
        logger.notice("Created AppSettings.plist for \(composition)")

        // A build that ran Wine has a prefix with drives; one that didn't (a
        // download ScummVM runs) has a bare C: drive, and nothing to point.
        if fileManager.fileExists(atPath: WrappLayout(app: wrappPath).prefix.appendingPathComponent("dosdevices").path) {
            // Each store the launch mounts as a drive (`target=A:`) has one,
            // standing in for the player's files until the wrapp points it at
            // them each time it starts; Documents, where the same store is
            // mounted too, leads where its drive does (WineDrives has why). A
            // build with no launch recorded gives the saves A:, as every
            // wrapp's always were.
            let wine = Wine(wrapp: wrappPath)
            let mounts = launch?.mounts ?? [
                RecordedLaunch.Mount(store: "app:wine-documents", target: "wine:A:"),
                RecordedLaunch.Mount(store: "app:wine-documents", target: "wine:C:/users/crossover/Documents"),
            ]
            for mount in mounts {
                guard let drive = mount.wineDrive else { continue }
                if (try? wine.drives.target(of: drive)) == nil {
                    try wine.drives.mount("/tmp/second-chance-nancy-drew-\(UUID().uuidString)", as: drive)
                }
                guard mounts.contains(where: { $0.store == mount.store && $0.target == "wine:C:/users/crossover/Documents" }) else { continue }
                try? FileManager.default.removeItem(at: wine.documents)
                try FileManager.default.createSymbolicLink(atPath: wine.documents.path, withDestinationPath: try wine.drives.target(of: drive))
            }
        }
    }

    /// The recorded launch's program is in the app, once the build has made
    /// it, where its module places it (`places`): a Wine or DOSBox program's
    /// file, a ScummVM game's folder. A program its module gives no place in
    /// the app (`steam://`) isn't checked; a bare one above the app is wrong.
    nonisolated static func checkLaunchProgram(_ launch: RecordedLaunch, in wrappPath: URL, places: PathPlaces = .shipped) throws {
        // Steam's and Big Fish's launches name the program they start.
        let program = launch.startedProgram
        guard let location = WrappLayout(app: wrappPath).location(program, places: places) else {
            guard program.hasPrefix("/") else {
                logger.notice("LAUNCH's program has no place in the app to check: \(program)")
                return
            }
            throw WrappBuildError.buildRecipeProblem("LAUNCH \(program) isn't in the app")
        }
        guard FileManager.default.fileExists(atPath: location.path) else {
            logger.critical("❌ The build didn't make what LAUNCH runs, \(program) (\(location.path))")
            throw WrappBuildError.gameExecutableNotFound
        }
        logger.notice("✓ LAUNCH's program is there: \(program)")
    }

    /// Each `files=` mount's target is a folder in the app once it's built:
    /// the files the store holds are linked in beside what's there, so the
    /// folder must be (docs/wrappfile.md#the-launch-volumes-and-app).
    nonisolated static func checkLaunchMounts(_ launch: RecordedLaunch, in wrappPath: URL, places: PathPlaces = .shipped) throws {
        for mount in launch.mounts where mount.filePatterns != nil {
            guard let folder = WrappLayout(app: wrappPath).location(mount.target, places: places) else {
                throw WrappBuildError.buildRecipeProblem("LAUNCH's files= mount of \(mount.store) at \(mount.target) isn't in the app")
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw WrappBuildError.buildRecipeProblem("LAUNCH's files= mount of \(mount.store) is at \(mount.target), which the build didn't make")
            }
        }
    }

    /// Whether a step copies into the app itself, outside the prefix: a
    /// `COPY` to a bare `/…` path. Builders run these after the cached
    /// install layer, which holds the prefix alone.
    nonisolated static func isAppStep(_ step: PlannedStep) -> Bool {
        step.module == nil && step.instruction == "COPY" && step.arguments.last?.hasPrefix("/") == true
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
                // A disc's folders and files are read-only; the app's copies
                // needn't be, or a later disc couldn't replace one, nor the
                // app be removed.
                _ = chmod(into.path, 0o755)
                // AppleDouble files (`._name`) are a Mac file's resource fork
                // and Finder info, as a hybrid disc's ISO side lists them:
                // metadata, not the program's.
                for name in try files.contentsOfDirectory(atPath: from.path) where !name.hasPrefix("._") {
                    let source = from.appendingPathComponent(name), target = into.appendingPathComponent(name)
                    var isFolder: ObjCBool = false
                    files.fileExists(atPath: source.path, isDirectory: &isFolder)
                    var targetIsFolder: ObjCBool = false
                    let exists = files.fileExists(atPath: target.path, isDirectory: &targetIsFolder)
                    if exists, !(isFolder.boolValue && targetIsFolder.boolValue) { try files.removeItem(at: target) }
                    if isFolder.boolValue {
                        try merge(source, target)
                        continue
                    }
                    // Contents alone, as DiscCopy copies a disc: a resource
                    // fork or Finder info would fail the app's codesign.
                    guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [
                            NSFilePathErrorKey: target.path,
                            NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                        ])
                    }
                    _ = chmod(target.path, 0o644)
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
        edition: String? = nil,
        updated: WrappLock.UpdateRecord? = nil,
        launch: RecordedLaunch? = nil,
        app: RecordedApp = RecordedApp(),
        input: WrappBuildInput
    ) async throws -> URL {
        // What it was built from, for updating it and for reports; its
        // bundle names the wrapp's bundle id. Checking the bundle runs ajv:
        // off the main thread.
        let edition = edition ?? Self.edition(of: source)
        let slug = gameInfo.id, lockComposition = composition ?? launch.map(Composition.init(launch:)) ?? gameInfo.composition
        var lock = try await Blocking.run {
            try ShippedBundles.lock(forGame: slug, edition: edition, source: source, composition: lockComposition)
        }
        lock.updated = updated
        if let launch {
            try Self.checkLaunchProgram(launch, in: wrappPath, places: places)
            try Self.checkLaunchMounts(launch, in: wrappPath, places: places)
        }
        try await configureWrapp(
            at: wrappPath, gameInfo: gameInfo, source: source, gameExePath: gameExePath, installerDir: installerDir,
            steamID: steamID, composition: composition, steamLaunchMode: steamLaunchMode,
            bigFishLaunchFile: bigFishLaunchFile, bigFishSKU: bigFishSKU, bigFishTrial: bigFishTrial,
            bundleID: lock.wrappBundleID, launch: launch, app: app
        )
        // A program whose launch has no Wine (a ScummVM game whose data is in
        // the app) keeps no prefix: what was built in one isn't the app's.
        if let launch, !(composition ?? Composition(launch: launch)).has(.wine), launch.launcher() != .wine {
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

    /// A build's working folder (`SecondChance-build-<id>` in the per-user
    /// temporary folder), holding a tree for each of its stages, registered
    /// for cleanup as a temporary wrapp is: removed when the build ends, its
    /// Wine ended on quit, and swept if a build that crashed left it
    /// (docs/wrapp-build.md#stages-as-trees).
    func createBuildFolder() -> URL {
        let path = fileManager.temporaryDirectory.appendingPathComponent("SecondChance-build-\(UUID().uuidString)")
        registerTemporaryWrapp(path)
        return path
    }

    /// The trees in a working folder, or the wrapp itself.
    nonisolated static func trees(in path: URL) -> [URL] {
        guard path.pathExtension != "app" else { return [path] }
        return ((try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
    }

    /// An engine, by its module's id and version, from the engine store,
    /// which fetches and prepares it the first time a build on this Mac
    /// needs it: what the runner's `ENGINE` steps install.
    func engine(_ id: String, version: String) async throws -> EngineStore.Engine {
        guard let resources = Bundle.main.resourceURL else { throw WrappBuildError.templateDamaged("Second Chance has no resources") }
        let modules = try await Blocking.run { try ModuleLoader(root: resources.appendingPathComponent("Modules"), added: AddedModules.folder()).loadAll().get() }
        guard let module = modules.first(where: { $0.manifest.id == id }) else {
            throw WrappBuildError.buildRecipeProblem("there's no \(id) module to install the engine of")
        }
        do {
            let engine = try await engines.engine(module, version: version) { step in logger.notice("[Engine] \(step)") }
            logger.notice("[Engine] \(engine.prepared ? "Prepared" : "Using the stored") \(id) \(engine.version) (\(engine.hash.prefix(12))…)")
            if id == ModuleID.basilisk.rawValue { try await ensureMacROM() }
            return engine
        } catch let error as DownloadError {
            logger.error("[Engine] Couldn't fetch \(id): \(error.description)")
            for failure in error.failures { logger.error("[Engine]   \(failure)") }
            throw WrappBuildError.engineUnavailable
        }
    }

    /// The ROM the basilisk module's Mac boots, kept in the engine store
    /// (`MacROMs`), where the build finds it (`module:basilisk:/rom`). A
    /// Debug build downloads one when there's none, as it would an engine,
    /// so development and test Macs need nothing by hand; a Release build
    /// never does: the ROM is the person's own (docs/modules.md).
    func ensureMacROM() async throws {
        let root = engines.root
        if MacROMs.kept(in: root) != nil { return }
        #if DEBUG
        // archive.org's "Macintosh Quadra 800 ROM", an F1ACAD13 ROM; only
        // in a Debug build, so a released Second Chance never names it.
        guard let url = URL(string: "https://archive.org/download/800_20250604/800.ROM") else { throw WrappBuildError.macROMNeeded }
        logger.notice("[Engine] No Mac ROM kept: a Debug build downloads the development copy")
        do {
            let download = try await DownloadWrappBuilder.standardDownloader()
                .fetch(DownloadRequest(urls: [url], sha256: "05ad753fb594e656cf078023ec189e09e2a7655a780de993b75b8c51ed6b09ca"))
            let kept = try await Blocking.run { try MacROMs.keep(download.file, in: root) }
            logger.notice("[Engine] Kept the Mac ROM: \(kept.lastPathComponent)")
        } catch let error as DownloadError {
            logger.error("[Engine] Couldn't fetch the development Mac ROM: \(error.description)")
            throw WrappBuildError.engineUnavailable
        }
        #else
        logger.error("[Engine] No Mac ROM is kept in \(MacROMs.folder(in: root).path)")
        throw WrappBuildError.macROMNeeded
        #endif
    }

    /// The template, checked: what the assembler lays into a tree at the end.
    func template() async throws -> URL {
        guard let templatePath = Bundle.main.url(forResource: "WrappTemplate", withExtension: "app") else {
            throw WrappBuildError.templateDamaged("WrappTemplate.app not found in Second Chance.app bundle")
        }
        try await verifyTemplateSignatures(templatePath)
        return templatePath
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
    /// A failed build's folder removed, or with `SECOND_CHANCE_KEEP_FAILED_BUILD=1`
    /// (`sc … --debug keep-failed-build`) kept for a look, its path logged:
    /// what an integration run's failure is diagnosed from.
    func removeFailedBuild(_ path: URL) async {
        if ProcessInfo.processInfo.environment["SECOND_CHANCE_KEEP_FAILED_BUILD"] == "1", fileManager.fileExists(atPath: path.path) {
            Self.untrack(path)
            logger.notice("Keeping the failed build's folder for a look: \(path.path)")
            return
        }
        await removeTempWrapp(path)
    }

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
        for tree in Self.trees(in: path) { await Wine(wrapp: tree).server.stop() }

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
        for wrapp in candidates where (wrapp.lastPathComponent.hasPrefix("NancyDrew-") && wrapp.pathExtension == "app")
            || wrapp.lastPathComponent.hasPrefix("SecondChance-build-") {
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
        let wrapps = tracking.withLock { Array($0.wrapps) }.flatMap(trees(in:))
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
