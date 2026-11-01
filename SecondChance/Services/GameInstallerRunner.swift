//
//  GameInstallerRunner.swift
//  SecondChance
//
//  Runs a Windows game installer inside a wrapp and locates the resulting
//  game executable. Owns the installer-execution machinery: command
//  building, AutoIt automation, MSI log streaming, the silent→interactive
//  retry loop, before/after exe diffing, and post-install game patches.
//

import Foundation
import Logging
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

private nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.Wine")

/// Runs the game's own installer (setup.exe / .msi) inside the Wine prefix
/// and finds what it installed.
///
/// Build-aware: knows about installer types (MSI, InstallShield, Inno Setup),
/// silent/interactive strategies, and AutoIt automation. Delegates actual
/// execution to WineManager.
class GameInstallerRunner {
    static let shared = GameInstallerRunner()

    /// Asked whether to carry on without a patch that failed: true to go on,
    /// false to stop the build. Each build passes its own input's
    /// (`WrappBuildInput.confirmPatchFailure`), which answers from
    /// `PATCH_FAILURE_POLICY`, carries on in a headless run and asks in the GUI.
    typealias PatchFailureConfirmation = @MainActor (GamePatch, Error) async -> Bool

    private let fileManager = FileManager.default
    private let catalog: GamePatchCatalog
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner")
    let bus: EventBus<AppEvent>

    init(
        catalog: GamePatchCatalog = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.catalog = catalog
        self.bus = bus
    }

    // MARK: - Game Installation

    /// Install game using Wine
    func installGameWithWine(
        wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource,
        installerPath: URL? = nil,
        installerName: String? = nil,
        unattended: Bool,
        confirmPatchFailure: PatchFailureConfirmation
    ) async throws -> (gameExePath: String, installerDir: String) {
        let driveCPath = WrappLayout(app: wrappPath).driveC

        // Find installer executable
        let installerExe: String
        if let installerPath = installerPath {
            // Direct installer path provided
            installerExe = installerPath.path
        } else {
            // Find setup.exe in disk directories
            let installerDir = try findInstallerDirectory(in: driveCPath)
            installerExe = try findInstallerExecutable(in: installerDir, preferring: installerName)
        }

        // Get list of exe files before installation
        let exesBefore = await Blocking.run { Self.findExecutableFiles(in: driveCPath) }

        // Check if debug mode is enabled to skip installer
        let skipInstaller = DebugSettings.shared.skipInstaller

        if skipInstaller {
            logger.notice("DEBUG: Skip installer enabled — using installer path as game exe: \(installerExe)")

            // Show what command would have been run using the same code path
            let installerType = await detectInstallerType(installerExe)
            let command = buildInstallerCommand(
                installerPath: installerExe,
                installerType: installerType,
                gameInfo: gameInfo,
                wrappPath: wrappPath,
                attemptNumber: 0
            )
            logger.notice("DEBUG: Would have run: \(command.commandDescription)")
            if let underlyingCommand = command.underlyingCommandDescription {
                logger.notice("DEBUG:    Automating: \(underlyingCommand)")
            }

            // Use the installer executable path as the game executable
            // This allows testing the wrapp without actually installing
            let installerURL = URL(fileURLWithPath: installerExe)
            let relativePath = installerURL.path(relativeTo: driveCPath)
            let installerDir = installerDirectoryPath(in: driveCPath)

            await bus.publishWrappBuild(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))
            return ("/" + relativePath, installerDir)
        }

        // The fallback is the installer's own wizard, so it needs someone to
        // click through it: never in strict mode, and never headless or under
        // test, where it would wait for ever (an integration run's builds
        // held a build slot for 50 minutes on a wizard nobody clicked).
        // `unattended` is the build's own answer (`WrappBuildInput.isUnattended`),
        // so the runner and the prompts agree on whether anyone is there.
        let strictInstall = ProcessInfo.processInfo.environment["STRICT_INSTALL"] == "true"
        let unattended = unattended || TestHost.isRunning
        let maxAttempts = (strictInstall || unattended) ? 1 : 2
        if unattended && !strictInstall {
            logger.notice("Unattended build: no interactive installer retry if the silent install fails")
        }

        // Try installation with automatic/silent mode first
        var installAttempt = 0
        var gameExe: URL?
        var installerType = InstallerType.unknown

        while gameExe == nil && installAttempt < maxAttempts {
            logger.notice("🔄 Installation attempt \(installAttempt + 1) of \(maxAttempts)")
            do {
                // Run installer
                let attempt = installAttempt
                installerType = try await retryingIfNoDisplay(at: wrappPath, "The installer") {
                    try await self.runInstaller(
                        at: wrappPath,
                        installerPath: installerExe,
                        gameInfo: gameInfo,
                        attemptNumber: attempt
                    )
                }
                await bus.publishWrappBuild(.instructions(nil))

                // Get list of exe files after installation
                let exesAfter = await Blocking.run { Self.findExecutableFiles(in: driveCPath) }

                // Try to find the game executable
                do {
                    gameExe = try findGameExecutable(
                        before: exesBefore,
                        after: exesAfter,
                        expectedPath: gameInfo.internalGameExePath,
                        driveCPath: driveCPath
                    )
                    if let found = gameExe {
                        do {
                            try await checkInstallFinished(
                                gameDir: found.deletingLastPathComponent(),
                                installerType: installerType,
                                driveCPath: driveCPath
                            )
                        } catch {
                            gameExe = nil
                            throw error
                        }
                    }
                } catch let error as WrappBuildError where error.isIncompleteInstall {
                    throw error
                } catch {
                    try Task.checkCancellation()
                    // Game executable not found
                    if installAttempt + 1 < maxAttempts {
                        logger.warning("Game exe not found after silent install — retrying with interactive mode...")
                        installAttempt += 1
                        await bus.publishWrappBuild(.progress(.installingGame(substep: Self.retryingInstallSubstep)))
                        await Wine(wrapp: wrappPath).server.stop()
                    } else {
                        // Strict mode or second attempt failed, throw the error
                        if strictInstall {
                            logger.critical("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                        } else if unattended {
                            logger.critical("❌ Silent installation failed, and an unattended build can't fall back to the interactive installer")
                        }
                        throw error
                    }
                }
            } catch {
                await bus.publishWrappBuild(.instructions(nil))
                // A cancelled build stops here: it is not a failed attempt
                // to retry with the installer's own wizard.
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                installAttempt += 1
                if installAttempt >= maxAttempts {
                    if strictInstall {
                        logger.critical("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                    } else if unattended {
                        logger.critical("❌ Silent installation failed, and an unattended build can't fall back to the interactive installer")
                    } else {
                        logger.critical("❌ Installation failed after \(installAttempt) attempts")
                    }
                    if case WineError.stalled = error {
                        throw WrappBuildError.installStalled
                    }
                    throw error
                }

                // Say why the installer's own wizard is about to appear.
                let isStall: Bool
                if case WineError.stalled = error { isStall = true } else { isStall = false }
                await bus.publishWrappBuild(.progress(.installingGame(
                    substep: isStall ? Self.stalledInstallSubstep : Self.retryingInstallSubstep)))
                logger.warning("Silent install failed: \(error) — retrying with interactive mode...")
                // Start the next attempt in a fresh Wine session: what the
                // failed one left running is no use to it, and its desktop
                // may be on its way out while its display key still says it
                // is up, which would let the next attempt skip starting one.
                await Wine(wrapp: wrappPath).server.stop()
            }
        }

        // The loop only ends without throwing once the exe is found, but say
        // so rather than crash if that ever stops being true.
        guard let gameExe else {
            logger.critical("❌ Installation finished without a game executable")
            throw WrappBuildError.gameExecutableNotFound
        }

        // Get relative path from drive_c
        // Use proper path manipulation to avoid issues with /private symlinks
        let relativePath = gameExe.path(relativeTo: driveCPath)

        // Determine the installer directory (disk-combined or disk-1)
        let installerDir = installerDirectoryPath(in: driveCPath)

        await bus.publishWrappBuild(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))

        // Apply any available game patches
        try await applyGamePatches(
            wrappPath: wrappPath,
            gameInfo: gameInfo,
            gameInstallDir: gameExe.deletingLastPathComponent(),
            source: source,
            confirmFailure: confirmPatchFailure
        )

        // Only logged: it says why a launch will likely fail, and which
        // editions of a game carry it.
        if let protection = await Blocking.run({ CopyProtection(exeAt: gameExe) }) {
            logger.warning("\(gameExe.lastPathComponent) is wrapped in \(protection.name) copy protection, which may not run under Wine")
        }

        return ("/" + relativePath, installerDir)
    }

    // MARK: - InstallShield Launchers

    /// Unpack an InstallShield "Setup Launcher" — one `setup.exe` with a
    /// disc's `Disk1` inside it, which is how Her Interactive sells its
    /// Windows downloads — into `drive_c/nancy-drew-installer/disk-1`. From
    /// there the installer runs as it would from a disc: silently with an
    /// answer file, then through the same completion check.
    ///
    /// `/extract_all:<dir>` writes the files into a `Disk1` folder inside
    /// `<dir>`, so they are unpacked beside `disk-1` and the folder holding
    /// `setup.exe` is then moved into its place.
    ///
    /// Returns false, having changed nothing, for an installer that isn't an
    /// InstallShield launcher or that doesn't unpack; it is then run as it is.
    func unpackInstallShieldLauncher(_ launcher: URL, at wrappPath: URL) async throws -> Bool {
        guard await detectInstallerType(launcher.path) == .installShield else {
            logger.notice("\(launcher.lastPathComponent) isn't an InstallShield launcher — running it as it is")
            return false
        }
        let installerBaseDir = WrappLayout(app: wrappPath).installers
        let unpacked = installerBaseDir.appendingPathComponent("unpacked")
        let disk1 = installerBaseDir.appendingPathComponent("disk-1")
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: unpacked) }

        logger.notice("Unpacking \(launcher.lastPathComponent) into C:\\nancy-drew-installer\\unpacked")
        let exitCode = try await retryingIfNoDisplay(at: wrappPath, "The installer launcher") {
            let desktop = await self.startDesktop(at: wrappPath)
            defer { desktop?.release() }
            // A launcher that won't unpack isn't a failure: it's run as it is.
            let exitCode: Int32
            do {
                try await Wine(wrapp: wrappPath).run(.program(launcher.path, ["/extract_all:C:\\nancy-drew-installer\\unpacked"]),
                                                     timeout: Self.unpackTimeout)
                exitCode = 0
            } catch WineError.executionFailed(let code) {
                exitCode = code
            }
            try await self.waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: Self.unpackTimeout)
            return exitCode
        }

        guard exitCode == 0, let setupDir = directoryContainingSetup(in: unpacked) else {
            logger.warning("\(launcher.lastPathComponent) didn't unpack (exit \(exitCode), no setup.exe) — running it as it is")
            return false
        }
        if fileManager.fileExists(atPath: disk1.path) {
            try fileManager.removeItem(at: disk1)
        }
        try fileManager.moveItem(at: setupDir, to: disk1)
        logger.notice("Unpacked \(launcher.lastPathComponent) (\(setupDir.lastPathComponent)) into C:\\nancy-drew-installer\\disk-1")
        return true
    }

    /// `dir` itself, or the one folder directly in it, if it holds a `setup.exe`.
    private func directoryContainingSetup(in dir: URL) -> URL? {
        func hasSetup(_ candidate: URL) -> Bool {
            let contents = (try? fileManager.contentsOfDirectory(atPath: candidate.path)) ?? []
            return contents.contains { $0.lowercased() == "setup.exe" }
        }
        if hasSetup(dir) { return dir }
        let children = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.first { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && hasSetup(child)
        }
    }

    /// Unpacking copies the download once, so a few minutes even for the
    /// largest; it takes seconds on an idle Mac.
    private static let unpackTimeout: TimeInterval = 600

    /// Install game using ScummVM (no actual installer needed - just returns disk path)
    func installGameWithScummVM(
        wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource,
        confirmPatchFailure: PatchFailureConfirmation
    ) async throws -> (gameExePath: String, installerDir: String) {
        // For ScummVM games, the "installation" is simply having the disk files available
        // The disk files were already copied by wrappBuilder.copyGameDisks()
        // We just need to return the path where the game files are located

        // ScummVM games don't need installation - they run directly from the disk files
        // The game files are located in SharedSupport/nancy-drew-installer/disk-1 (or disk-combined)

        let driveCPath = WrappLayout(app: wrappPath).driveC
        let gameDir = try findInstallerDirectory(in: driveCPath)

        // Return the path relative to drive_c
        // This will be used by ScummVM's --path argument
        let relativePath = gameDir.path(relativeTo: driveCPath)
        let relativeInstallerDir = gameDir.path(relativeTo: driveCPath)
        await bus.publishWrappBuild(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))

        // The early games run under ScummVM, but their official patches are
        // still Windows installers that rewrite the game's data files. Wine is
        // still in the wrapp at this point — `cleanupUnusedEngine` strips it
        // one step later — so the patches can be applied here and nowhere else.
        try await applyGamePatches(
            wrappPath: wrappPath,
            gameInfo: gameInfo,
            gameInstallDir: gameDir,
            source: source,
            confirmFailure: confirmPatchFailure
        )

        return ("/" + relativePath, "/" + relativeInstallerDir)
    }

    // MARK: - Disk Directory Resolution

    /// The folder the game installs from: `disk-combined` for a game on two
    /// discs, else `disk-1`; nil if neither is there.
    private func installerDirectory(in driveCPath: URL) -> URL? {
        let base = driveCPath.appendingPathComponent(WrappLayout.installersFolder)
        return ["disk-combined", "disk-1"].map { base.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// `installerDirectory`, or `diskNotFound`.
    private func findInstallerDirectory(in driveCPath: URL) throws -> URL {
        guard let directory = installerDirectory(in: driveCPath) else {
            logger.critical("Could not find disk directory — expected disk-1 or disk-combined in \(driveCPath.appendingPathComponent(WrappLayout.installersFolder).path)")
            throw WrappBuildError.diskNotFound
        }
        logger.notice("Installing from \(directory.lastPathComponent)")
        return directory
    }

    /// The installer directory as a Windows-style path relative to drive_c
    /// (e.g. "/nancy-drew-installer/disk-1").
    private func installerDirectoryPath(in driveCPath: URL) -> String {
        guard let directory = installerDirectory(in: driveCPath) else { return "/" + WrappLayout.installersFolder }
        return "/\(WrappLayout.installersFolder)/\(directory.lastPathComponent)"
    }

    // MARK: - Game Patches

    /// How long a single patch installer gets before it is assumed to be
    /// sitting on a dialog that nobody can answer. Most take seconds, but with
    /// every core busy one has needed minutes just to start its Wine session.
    private static let patchInstallerTimeout: TimeInterval = 900

    /// Something that went wrong applying one patch. Every case is recoverable:
    /// the build continues without that patch unless the user says otherwise.
    enum GamePatchError: LocalizedError {
        case archiveMissing(String)
        case payloadMissing(payload: String, archive: String)
        case unzipFailed(String)
        case timedOut(String)
        case installerFailed(id: String, exitCode: Int32)
        case installerDidNotFinish(id: String, reason: String)
        case automationFailed(id: String, script: String)
        case changedNothing(id: String)

        var errorDescription: String? {
            switch self {
            case .archiveMissing(let archive):
                return "The patch archive \(archive) was not bundled with Second Chance. It may have failed to download when Second Chance was built."
            case .payloadMissing(let payload, let archive):
                return "\(archive) did not contain the expected file \(payload)."
            case .unzipFailed(let archive):
                return "Could not unzip \(archive)."
            case .timedOut(let id):
                return "The patch installer for \(id) did not finish in time and was stopped."
            case .installerFailed(let id, let exitCode):
                return "The patch installer for \(id) exited with code \(exitCode)."
            case .installerDidNotFinish(let id, let reason):
                return "The patch installer for \(id) exited cleanly but didn't finish: \(reason)"
            case .automationFailed(let id, let script):
                return "\(script).au3 couldn't get the patch installer for \(id) to finish; its last lines above say where it stopped."
            case .changedNothing(let id):
                return "The patch installer for \(id) reported success but changed no game files."
            }
        }
    }

    /// Apply the official Her Interactive patches for this game.
    ///
    /// Which patches apply depends on the game *and* on the edition the wrapp
    /// was built from — Her Interactive shipped separate CD and
    /// digital-download builds of several patches, and the wrong one does
    /// nothing useful. Patches the manifest marks non-automatic (puzzle
    /// solvers, difficulty tweaks, superseded updaters) are logged but never
    /// applied. See `docs/game-patches.md`.
    ///
    /// A failing patch never fails the build on its own: it is reported, and
    /// `confirmFailure` decides whether to carry on without it. So this only
    /// throws to stop the build: `userCancelled` when the person chose to,
    /// or `CancellationError` when the build was cancelled.
    func applyGamePatches(
        wrappPath: URL,
        gameInfo: GameInfo,
        gameInstallDir: URL,
        source: WrappSource,
        confirmFailure: PatchFailureConfirmation
    ) async throws {
        let gameSlug = gameInfo.id
        let patches = catalog.automaticPatches(forGame: gameSlug, source: source)

        for skipped in catalog.optionalPatches(forGame: gameSlug, source: source) {
            logger.notice("⏭️  Optional patch not applied: \(skipped.id) — \(skipped.title)")
        }

        guard !patches.isEmpty else {
            logger.notice("ℹ️  No patches to apply for game '\(gameSlug)'")
            return
        }

        let driveCPath = WrappLayout(app: wrappPath).driveC

        logger.notice("🔧 Applying \(patches.count) patch(es) for '\(gameSlug)' (\(source.rawValue))...")

        for patch in patches {
            try Task.checkCancellation()
            logger.notice("📦 Patch: \(patch.id) — \(patch.title)")
            do {
                // A walk over every file of the game, off the main thread.
                let before = await Blocking.run { GameFileSnapshot(of: gameInstallDir) }
                try await apply(
                    patch,
                    wrappPath: wrappPath,
                    driveCPath: driveCPath,
                    gameInstallDir: gameInstallDir
                )
                let changed = await Blocking.run { GameFileSnapshot(of: gameInstallDir) }.changes(since: before)
                if changed.isEmpty {
                    // A driven patcher's exit code is only AutoIt's: it has
                    // once exited 0 without the patcher ever running.
                    guard patch.automation == nil else {
                        throw GamePatchError.changedNothing(id: patch.id)
                    }
                    logger.warning("   → \(patch.id) changed no files in \(gameInstallDir.lastPathComponent)")
                } else {
                    logger.notice("   → changed: \(changed.joined(separator: ", "))")
                }
                logger.notice("✅ Applied patch: \(patch.id)")
                await bus.publishWrappBuild(.patchApplied(id: patch.id))
            } catch {
                // Cancelling the build stops a patcher part way; that isn't
                // the patch failing.
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                logger.error("❌ Patch failed: \(patch.id): \(error.localizedDescription)")
                await bus.publishWrappBuild(.patchFailed(id: patch.id, message: error.localizedDescription))
                _ = FailureReporter.sendWithoutAsking(FailureReport(
                    what: "Applying a game patch", kind: ErrorChain.identifier(error),
                    game: gameInfo.id, source: source.rawValue, engine: gameInfo.gameEngine.rawValue,
                    tags: ["patch": patch.id]
                ))
                let continueInstall = await confirmFailure(patch, error)
                if continueInstall {
                    logger.notice("⚠️  Continuing without patch: \(patch.id)")
                } else {
                    throw WrappBuildError.userCancelled
                }
            }
        }

        logger.notice("✅ Finished applying patches for '\(gameSlug)'")
    }

    /// Unpack one patch archive and apply its payload to the installed game.
    private func apply(
        _ patch: GamePatch,
        wrappPath: URL,
        driveCPath: URL,
        gameInstallDir: URL
    ) async throws {
        guard let archiveURL = Bundle.main.url(
            forResource: patch.archive,
            withExtension: nil,
            subdirectory: "game-patches/\(patch.game)"
        ) else {
            throw GamePatchError.archiveMissing(patch.archive)
        }

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        try await unzipPatchArchive(archiveURL, into: tempDir)

        // The manifest names the payload exactly, so there is no guessing at
        // filenames — they follow no pattern worth pattern-matching.
        let payload = tempDir.appendingPathComponent(patch.payload)
        guard fileManager.fileExists(atPath: payload.path) else {
            throw GamePatchError.payloadMissing(payload: patch.payload, archive: patch.archive)
        }

        switch patch.action {
        case .copyIntoGameDir:
            let destinationDir = patch.destinationSubdirectory.map {
                gameInstallDir.appendingPathComponent($0)
            } ?? gameInstallDir
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            let destination = destinationDir.appendingPathComponent(patch.payload)
            // Overwrite rather than fail: rebuilding a wrapp must be idempotent.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: payload, to: destination)
            logger.notice("   → copied \(patch.payload) into \(destinationDir.lastPathComponent)")

        case .extractIntoGameDir:
            let destinationDir = patch.destinationSubdirectory.map {
                gameInstallDir.appendingPathComponent($0)
            } ?? gameInstallDir
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            // A self-extracting zip is a zip with an exe in front, which unzip
            // reads as is. -o overwrites, so a rebuild is idempotent.
            try await unzipPatchArchive(payload, into: destinationDir)
            logger.notice("   → extracted \(patch.payload) into \(destinationDir.lastPathComponent)")

        case .runInstaller:
            // Stage the installer next to the game: these old patchers default
            // to their own directory when asked where the game lives.
            let staged = gameInstallDir.appendingPathComponent(patch.payload)
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.copyItem(at: payload, to: staged)
            // Leave the game directory as we found it, patched or not.
            defer { try? fileManager.removeItem(at: staged) }

            let winePath = Self.windowsPath(of: staged, driveC: driveCPath)
            try await runPatchInstaller(patch, at: wrappPath, hostPath: staged, winePath: winePath)
        }
    }

    /// The Windows path (`C:\\…`) of a file inside the prefix's `drive_c`.
    ///
    /// Wine reads a path that starts with `/` as a Unix path, so cutting the
    /// `drive_c` prefix off alone leaves a path that names nothing.
    static func windowsPath(of file: URL, driveC: URL) -> String {
        let relative = file.standardizedFileURL.path.dropFirst(driveC.standardizedFileURL.path.count)
        return "C:" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    /// Extract a patch archive with `/usr/bin/unzip`.
    private func unzipPatchArchive(_ archive: URL, into directory: URL) async throws {
        let unzip = try await Process.output(of: "/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path])
        guard unzip.succeeded else {
            throw GamePatchError.unzipFailed(archive.lastPathComponent)
        }
    }

    /// Run a patch installer under Wine, silently where the installer type
    /// supports it, and bounded by a timeout.
    ///
    /// Wine execution has no timeout of its own and these are twenty-year-old
    /// wizard installers, so one that decides to show a dialog would otherwise
    /// hang the build forever. On timeout the prefix's wineserver is killed and
    /// the patch is reported failed, which routes through the normal
    /// patch-failure confirmation.
    private func runPatchInstaller(
        _ patch: GamePatch,
        at wrappPath: URL,
        hostPath: URL,
        winePath: String
    ) async throws {
        try await retryingIfNoDisplay(at: wrappPath, "\(patch.id)'s patcher") {
            try await self.runPatchInstallerOnce(patch, at: wrappPath, hostPath: hostPath, winePath: winePath)
        }
    }

    private func runPatchInstallerOnce(
        _ patch: GamePatch,
        at wrappPath: URL,
        hostPath: URL,
        winePath: String
    ) async throws {
        if let automation = patch.automation {
            try await runAutomatedPatchInstaller(patch, script: automation, at: wrappPath, winePath: winePath)
            return
        }

        let installerType = await detectInstallerType(hostPath.path)
        // An Inno Setup patcher keeps a log that says whether it finished;
        // the self-extracting updaters most patches are don't.
        let installerLog = installerType == .innoSetup
            ? try? prepareInstallerLog(in: wrappPath, format: .inno)
            : nil
        defer {
            if let installerLog, !DebugSettings.shared.debugMode {
                try? fileManager.removeItem(at: installerLog.hostPath)
            }
        }
        let arguments = silentPatchArguments(for: installerType, logPath: installerLog?.windowsPath)
        logger.notice("   → running \(patch.payload) (\(installerType)) \(arguments.joined(separator: " "))")

        // Wine.run stops the prefix's wineserver on timeout, which is the only
        // thing that ends the Windows process.
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        do {
            try await Wine(wrapp: wrappPath).run(.program(winePath, arguments), timeout: Self.patchInstallerTimeout)
        } catch WineError.executionFailed(let code) {
            throw GamePatchError.installerFailed(id: patch.id, exitCode: code)
        } catch WineError.timedOut {
            throw GamePatchError.timedOut(patch.id)
        }
        do {
            try await waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: Self.patchInstallerTimeout)
        } catch WineError.timedOut {
            throw GamePatchError.timedOut(patch.id)
        }
        if let installerLog {
            try checkInstallerLog(installerLog, failure: { GamePatchError.installerDidNotFinish(id: patch.id, reason: $0) })
        }
    }

    /// Run a patcher that has no silent mode through its AutoIt script, which
    /// clicks through the wizard and exits 0 only once the patcher says the
    /// game was updated. The script's output lands in the log.
    private func runAutomatedPatchInstaller(
        _ patch: GamePatch,
        script: String,
        at wrappPath: URL,
        winePath: String
    ) async throws {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let scriptPath = try await stageAutoIt(script: script, inDriveC: driveCPath)
        defer { removeAutoIt(script: scriptPath, inDriveC: driveCPath) }

        let scriptWinePath = Self.windowsPath(of: scriptPath, driveC: driveCPath)
        logger.notice("   → running \(patch.payload) through AutoIt (\(script).au3)")
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        let autoIt = Self.windowsPath(of: driveCPath.appendingPathComponent("autoit/AutoIt3.exe"), driveC: driveCPath)
        // The script failing still waits for what the patcher started.
        let exitCode: Int32
        do {
            do {
                // /ErrorStdOut: a script error is printed (and logged) rather than
                // shown in a message box nobody will close.
                try await Wine(wrapp: wrappPath).run(.program(autoIt, ["/ErrorStdOut", scriptWinePath, winePath]),
                                                     timeout: Self.patchInstallerTimeout)
                exitCode = 0
            } catch WineError.executionFailed(let code) {
                exitCode = code
            }
            try await waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: Self.patchInstallerTimeout)
        } catch WineError.timedOut {
            throw GamePatchError.timedOut(patch.id)
        }
        guard exitCode == 0 else {
            throw GamePatchError.automationFailed(id: patch.id, script: script)
        }
    }

    /// Copy AutoIt and a `patch-automation` script into the prefix, returning
    /// the script's host path.
    private func stageAutoIt(script: String, inDriveC driveCPath: URL) async throws -> URL {
        guard AutoItService.shared.isAvailable else {
            throw WrappBuildError.autoItNotAvailable
        }
        guard let source = Bundle.main.url(forResource: script, withExtension: "au3", subdirectory: "patch-automation") else {
            throw WrappBuildError.autoItScriptNotFound
        }
        let autoitDestDir = driveCPath.appendingPathComponent("autoit")
        if !fileManager.fileExists(atPath: autoitDestDir.path) {
            // Tens of MB, so off the main thread.
            let autoitDir = AutoItService.shared.autoitDir
            try await Blocking.run { try FileManager.default.copyItem(at: autoitDir, to: autoitDestDir) }
        }
        let destination = driveCPath.appendingPathComponent("\(script).au3")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// Remove what `stageAutoIt` copied, so the wrapp doesn't ship AutoIt.
    private func removeAutoIt(script: URL, inDriveC driveCPath: URL) {
        for item in [driveCPath.appendingPathComponent("autoit"), script] {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                logger.warning("Couldn't remove \(item.lastPathComponent) from the prefix: \(error.localizedDescription)")
            }
        }
    }

    /// Best-effort silent-install flags for a patch installer.
    ///
    /// Unlike the game installers there is no recorded `.iss` answer file for
    /// patches, so this is the generic flag set for each installer family. If
    /// an installer ignores them and shows a wizard, the timeout catches it.
    private func silentPatchArguments(for installerType: InstallerType, logPath: String?) -> [String] {
        switch installerType {
        case .msi:
            return ["/qn"]
        case .installShield:
            return ["/s", "/sms"]
        case .innoSetup:
            return ["/verysilent", "/norestart"] + (logPath.map { ["/LOG=\($0)"] } ?? [])
        case .unknown:
            return []
        }
    }

    // MARK: - AutoIt Automation

    /// Copy AutoIt and automation script to Wine prefix for installer automation
    private func setupAutoItForInstall(in wrappPath: URL) async throws {
        let driveCPath = WrappLayout(app: wrappPath).driveC

        // Check if AutoIt is available
        guard AutoItService.shared.isAvailable else {
            throw WrappBuildError.autoItNotAvailable
        }

        // Copy AutoIt directory from bundle
        let autoitSourceDir = AutoItService.shared.autoitDir
        let autoitDestDir = driveCPath.appendingPathComponent("autoit")

        // Remove existing AutoIt directory if present
        if fileManager.fileExists(atPath: autoitDestDir.path) {
            try fileManager.removeItem(at: autoitDestDir)
        }

        // Copy AutoIt directory: tens of MB, so off the main thread.
        try await Blocking.run { try FileManager.default.copyItem(at: autoitSourceDir, to: autoitDestDir) }
        logger.notice("✅ Copied AutoIt to drive_c")

        // Copy automation script from bundle
        if let scriptPath = Bundle.main.path(forResource: "installshield-custom-dialog-automate", ofType: "au3") {
            let scriptDestPath = driveCPath.appendingPathComponent("installshield-custom-dialog-automate.au3")

            // Remove existing script if present
            if fileManager.fileExists(atPath: scriptDestPath.path) {
                try fileManager.removeItem(at: scriptDestPath)
            }

            try fileManager.copyItem(atPath: scriptPath, toPath: scriptDestPath.path)
            logger.notice("✅ Copied AutoIt script to drive_c")
        } else {
            throw WrappBuildError.autoItScriptNotFound
        }
    }

    /// Remove AutoIt files from Wine prefix after installation
    private func cleanupAutoItAfterInstall(in wrappPath: URL) {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let autoitDir = driveCPath.appendingPathComponent("autoit")
        let scriptPath = driveCPath.appendingPathComponent("installshield-custom-dialog-automate.au3")

        // Remove AutoIt directory
        if fileManager.fileExists(atPath: autoitDir.path) {
            try? fileManager.removeItem(at: autoitDir)
            logger.notice("🧹 Cleaned up AutoIt directory")
        }

        // Remove script
        if fileManager.fileExists(atPath: scriptPath.path) {
            try? fileManager.removeItem(at: scriptPath)
            logger.notice("🧹 Cleaned up AutoIt script")
        }
    }

    // MARK: - Installer Command Building

    /// Information about how to execute an installer
    private struct InstallerCommand {
        let exePath: String
        let arguments: [String]
        let useStartCommand: Bool
        let commandDescription: String
        /// Non-nil when AutoIt automates an underlying installer command.
        /// This is the single source of truth for "is AutoIt being used".
        let underlyingCommandDescription: String?
    }

    /// Host and Windows paths for an installer's own log file.
    private struct InstallerLogFile {
        let format: InstallerLogFormat
        let hostPath: URL
        let windowsPath: String
    }

    /// Build a unique installer log file path in the Wine prefix temp directory.
    private func prepareInstallerLog(in wrappPath: URL, format: InstallerLogFormat) throws -> InstallerLogFile {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let windowsTempDir = driveCPath.appendingPathComponent("windows/temp")
        try fileManager.createDirectory(at: windowsTempDir, withIntermediateDirectories: true)

        let fileName = "nancy-drew-install-\(UUID().uuidString).log"
        let hostPath = windowsTempDir.appendingPathComponent(fileName)
        fileManager.createFile(atPath: hostPath.path, contents: nil)

        return InstallerLogFile(
            format: format,
            hostPath: hostPath,
            windowsPath: "C:\\windows\\temp\\\(fileName)"
        )
    }

    /// Stream an installer log file line-by-line to a dedicated logger.
    private func startInstallerLogStreaming(_ log: InstallerLogFile, onLine: (@Sendable (String) -> Void)? = nil) throws -> InstallerLogStreamer {
        let streamer = InstallerLogStreamer(logPath: log.hostPath, format: log.format)
        streamer.onLine = onLine
        try streamer.start()
        return streamer
    }

    /// Build the installer command that should be executed
    private func buildInstallerCommand(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrappPath: URL,
        attemptNumber: Int,
        logPath: String? = nil
    ) -> InstallerCommand {
        // Get installer arguments
        let args = getInstallerArguments(
            installerPath: installerPath,
            installerType: installerType,
            gameInfo: gameInfo,
            wrappPath: wrappPath,
            attemptNumber: attemptNumber,
            logPath: logPath
        )

        // Check if we need to use AutoIt for this installer
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let setupIssPath = driveCPath.appendingPathComponent(WrappLayout.installersFolder).appendingPathComponent("setup.iss")
        let useAutoIt = installerType == .installShield &&
                       attemptNumber == 0 &&
                       fileManager.fileExists(atPath: setupIssPath.path) &&
                       gameInfo.doesNotExitInNonInteractiveMode

        if useAutoIt {
            let autoitArgs = [
                "C:\\installshield-custom-dialog-automate.au3",
                installerPath,
                gameInfo.title
            ]
            let underlyingCommand = installerType == .msi
                ? "msiexec \(args.joined(separator: " "))"
                : "wine start /wait \(installerPath) \(args.joined(separator: " "))"

            return InstallerCommand(
                exePath: "C:\\autoit\\AutoIt3.exe",
                arguments: autoitArgs,
                useStartCommand: false,
                commandDescription: "C:\\autoit\\AutoIt3.exe \(autoitArgs.joined(separator: " "))",
                underlyingCommandDescription: underlyingCommand
            )
        } else if installerType == .msi {
            return InstallerCommand(
                exePath: "msiexec",
                arguments: args,
                useStartCommand: false,
                commandDescription: "msiexec \(args.joined(separator: " "))",
                underlyingCommandDescription: nil
            )
        } else {
            return InstallerCommand(
                exePath: installerPath,
                arguments: args,
                useStartCommand: true,
                commandDescription: "wine start /wait \(installerPath) \(args.joined(separator: " "))",
                underlyingCommandDescription: nil
            )
        }
    }

    // MARK: - Install Checks

    /// Log what the install produced and, for InstallShield, fail unless it
    /// left its uninstall log, which it writes only once it has finished.
    /// (Inno Setup and MSI installs were already checked against their own
    /// logs in `runInstaller`.) See `InstallCompletion`.
    func checkInstallFinished(gameDir: URL, installerType: InstallerType, driveCPath: URL) async throws {
        // A walk over the whole game, so off the main thread.
        let size = await Blocking.run { DirectorySize.measure(gameDir) }
        logger.notice("Installed: \(size.description) in \(gameDir.lastPathComponent)")
        guard installerType == .installShield else { return }
        if let problem = InstallCompletion.installShieldProblem(gameDir: gameDir, driveC: driveCPath) {
            logger.error("Install is incomplete: \(problem)")
            throw WrappBuildError.installIncomplete(reason: problem)
        }
        logger.notice("InstallShield's uninstall log is in place: the install finished")
    }

    // MARK: - Installer Execution

    /// How long a silent or AutoIt-driven install may run:
    /// `SECOND_CHANCE_INSTALL_TIMEOUT` seconds, default 30 minutes — several
    /// times the slowest install seen under Rosetta.
    static var unattendedInstallTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SECOND_CHANCE_INSTALL_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 30 * 60
    }

    /// Run the installer with appropriate arguments based on installer type,
    /// and return that type. An Inno Setup or MSI install that exits 0 must
    /// also say it finished in its own log, or this throws
    /// `WrappBuildError.installIncomplete`.
    @discardableResult
    private func runInstaller(
        at wrappPath: URL,
        installerPath: String,
        gameInfo: GameInfo,
        attemptNumber: Int
    ) async throws -> InstallerType {
        let installerType = await detectInstallerType(installerPath)
        let installerTypeDesc = String(describing: installerType)
        logger.notice("Installer type: \(installerTypeDesc)")
        await bus.publishWrappBuild(.installerResolved(exePath: installerPath, type: installerType))

        // Diagnostic logging for the AutoIt decision (the decision itself is
        // made once, inside buildInstallerCommand).
        logger.debug("Attempt number: \(attemptNumber)")
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let setupIssPath = driveCPath.appendingPathComponent(WrappLayout.installersFolder).appendingPathComponent("setup.iss")
        let setupIssExists = fileManager.fileExists(atPath: setupIssPath.path)
        logger.debug("Setup.iss path: \(setupIssPath.path), exists: \(setupIssExists)")
        logger.debug("Game doesNotExitInNonInteractiveMode: \(gameInfo.doesNotExitInNonInteractiveMode)")

        let installerLog = InstallerLogFormat(installerType)
            .map { try? prepareInstallerLog(in: wrappPath, format: $0) } ?? nil
        if let installerLog {
            logger.notice("\(installerLog.format.name) install log file: \(installerLog.hostPath.path)")
        }

        // Build and print the command that will be executed
        let command = buildInstallerCommand(
            installerPath: installerPath,
            installerType: installerType,
            gameInfo: gameInfo,
            wrappPath: wrappPath,
            attemptNumber: attemptNumber,
            logPath: installerLog?.windowsPath
        )
        logger.notice("Running: \(command.commandDescription)")
        if let underlyingCommand = command.underlyingCommandDescription {
            logger.notice("   Automating: \(underlyingCommand)")
        }

        // An unattended attempt is watched for going quiet, which ends it long
        // before its timeout would (docs/wrapp-build.md#a-stalled-install).
        let stallWatch = attemptNumber == 0 ? InstallStallRule.fromEnvironment().map { rule in
            InstallStallWatch(rule: rule, driveC: driveCPath) { [bus] waiting in
                Task { await bus.publishWrappBuild(.instructions(waiting ? Self.installerQuestionInstructions : nil)) }
            }
        } : nil

        // Stream the installer's own log independently from Wine stdout/stderr.
        var logStreamer: InstallerLogStreamer?
        if let installerLog {
            logStreamer = try startInstallerLogStreaming(installerLog, onLine: stallWatch.map { watch in { _ in watch.sawOutput() } })
        }
        defer {
            if let logStreamer {
                logStreamer.stop()
            }
            if let installerLog, !DebugSettings.shared.debugMode {
                try? fileManager.removeItem(at: installerLog.hostPath)
            }
        }

        // Setup AutoIt if needed. Removed however this attempt ends, so a
        // failed one doesn't leave it in the wrapp (an interactive retry
        // doesn't use it), except in debug mode, to allow manual re-runs.
        let usesAutoIt = command.underlyingCommandDescription != nil
        if usesAutoIt {
            try await setupAutoItForInstall(in: wrappPath)
        }
        defer {
            if usesAutoIt {
                if DebugSettings.shared.debugMode {
                    logger.notice("DEBUG: Keeping AutoIt files for manual re-run")
                } else {
                    cleanupAutoItAfterInstall(in: wrappPath)
                }
            }
        }

        // An installer nothing drives shows its own wizard, for the person
        // to click through: say so, and what to choose.
        let interactive = command.underlyingCommandDescription == nil && runsInteractively(
            installerType: installerType, attemptNumber: attemptNumber, setupIssExists: setupIssExists)
        if interactive {
            logger.notice("The installer runs interactively: showing the install instructions")
            await bus.publishWrappBuild(.instructions(Self.interactiveInstallInstructions(for: gameInfo)))
        }

        // Execute the installer command. The WineManager methods return the
        // Wine exit code (already logged) rather than throwing for non-zero
        // exits. An unattended attempt gets a timeout, since nobody will
        // notice it hanging; the interactive one is someone working through
        // a wizard, who can take as long as they like.
        let timeout = attemptNumber == 0 ? Self.unattendedInstallTimeout : nil
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        stallWatch?.start()
        defer { stallWatch?.stop() }
        // A non-zero exit code usually means the install failed, and throws
        // `executionFailed`, so the caller's silent→interactive retry can kick in.
        let program: WineCommand = command.useStartCommand
            ? .start(command.exePath, command.arguments)
            : .program(command.exePath, command.arguments)
        try await Wine(wrapp: wrappPath).run(program, timeout: timeout, watchdog: stallWatch)

        try await waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: timeout, watchdog: stallWatch)

        // A clean exit isn't proof the install finished: check that the
        // installer's own log says it did.
        if let installerLog {
            try checkInstallerLog(installerLog, failure: { WrappBuildError.installIncomplete(reason: $0) })
        }
        return installerType
    }

    /// Wait until the prefix has no Windows processes left. `wine start
    /// /wait` returns when the program it started exits, but installers hand
    /// over to a copy of themselves and exit first: InstallShield 12's
    /// setup.exe relaunches from Temp (Lost Queen's returned with 71 MB of
    /// 2.2 GB copied), and Her Interactive's patch stubs unpack and run
    /// `_upd1.exe`. Until that copy is done, the install is still being
    /// written, so nothing about it can be checked.
    ///
    /// The pre-started desktop is released first: it would otherwise keep the
    /// session, and so this wait, going for ever.
    /// `watchdog` too, as an InstallShield `setup.exe` can exit in seconds and
    /// leave the whole install to the processes it started.
    private func waitForInstallerProcesses(at wrappPath: URL, releasing desktop: WineDesktop?, timeout: TimeInterval?,
                                           watchdog: WineWatchdog? = nil) async throws {
        desktop?.release()
        logger.notice("Waiting for the installer's remaining Wine processes to finish")
        try await Wine(wrapp: wrappPath).server.waitUntilProgramsExit(timeout: timeout, watchdog: watchdog)
    }

    /// Run `step`, and if its Windows program found no display, end the Wine
    /// session and run it once more, which starts it a fresh desktop.
    ///
    /// On a loaded machine a program has failed to find a desktop that
    /// `WineDesktop` had just reported ready (the cause isn't known), and the
    /// session then stays that way: the next program fails the same way
    /// within a second. Restarting the session is the surest way to a fresh
    /// desktop.
    private func retryingIfNoDisplay<T>(
        at wrappPath: URL,
        _ what: String,
        _ step: () async throws -> T
    ) async throws -> T {
        do {
            return try await step()
        } catch WineError.noDisplay {
            logger.warning("\(what) found no display to open its windows on — restarting the Wine session and trying once more")
            await Wine(wrapp: wrappPath).server.stop()
            return try await step()
        }
    }

    /// Start Wine's desktop before an installer or patcher runs, so it isn't
    /// left to Wine's 10-second on-demand start ("The explorer process failed
    /// to start", which once failed Stay Tuned's patch). See `WineDesktop`.
    /// A program run without it is sure to fail: AutoIt then can't open its
    /// window and exits 0 without having run its script.
    private func startDesktop(at wrappPath: URL) async -> WineDesktop? {
        await WineDesktop.start(Wine(wrapp: wrappPath), logger: logger, outputLogger: wineOutputLogger)
    }

    /// Throw `failure(reason)` unless the installer's log records it
    /// finishing; log the verdict either way.
    private func checkInstallerLog(_ log: InstallerLogFile, failure: (String) -> Error) throws {
        let text = InstallCompletion.readLog(at: log.hostPath) ?? ""
        let problem: String?
        switch log.format {
        case .inno: problem = InstallCompletion.innoProblem(log: text)
        case .msi: problem = InstallCompletion.msiProblem(log: text)
        }
        if let problem {
            logger.error("Install is incomplete: \(problem)")
            throw failure(problem)
        }
        logger.notice("\(log.format.name)'s log says the install finished")
    }

    // MARK: - Installer Type Detection

    /// Detect installer type from file extension and metadata
    func detectInstallerType(_ installerPath: String) async -> InstallerType {
        let url = URL(fileURLWithPath: installerPath)

        // Check file extension first
        if url.pathExtension.lowercased() == "msi" {
            return .msi
        }

        // InstallShield and Inno Setup name themselves in the installer's
        // version info. Mapped, so off the main thread.
        let strings = await Blocking.run { WindowsExecutable(contentsOf: url)?.versionStrings ?? [:] }
        logger.notice("🔍 Installer version info: ProductName=\(strings["ProductName"] ?? "–"), Comments=\(strings["Comments"] ?? "–")")
        let combined = [strings["ProductName"], strings["Comments"]].compactMap { $0 }.joined(separator: " ").lowercased()
        if combined.contains("installshield") {
            return .installShield
        } else if combined.contains("inno setup") {
            return .innoSetup
        }

        return .unknown
    }

    /// Whether the installer shows its own wizard rather than installing
    /// silently: what `getInstallerArguments` chooses, from the person's side.
    func runsInteractively(installerType: InstallerType, attemptNumber: Int, setupIssExists: Bool) -> Bool {
        switch installerType {
        case .msi, .innoSetup: return attemptNumber > 0
        case .installShield: return attemptNumber > 0 || !setupIssExists
        case .unknown: return true
        }
    }

    /// The progress screen's instructions while an installer's own window is
    /// up for the person to click through.
    /// The progress screen's instructions while an unattended install has
    /// gone quiet with one of its windows on screen.
    static let installerQuestionInstructions =
        "The game's installer is asking something in its own window. Answer it there, and the install will carry on."

    /// The progress screen's step while the stalled unattended install gives
    /// way to the installer's own window.
    static let stalledInstallSubstep = "The install got stuck, so the installer is opening for you to finish it"
    /// Shown when installing by itself didn't work for any other reason.
    static let retryingInstallSubstep = "Installing by itself didn't work, so the installer is opening for you to finish it"

    static func interactiveInstallInstructions(for gameInfo: GameInfo) -> String {
        let tips = gameInfo.installInstructions ?? GameInfo.defaultInstallInstructions
        return "The game's installer has opened in its own window. Click through it to install the game. \(tips)"
    }

    /// Get installer arguments based on type and attempt number
    func getInstallerArguments(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrappPath: URL,
        attemptNumber: Int,
        logPath: String? = nil
    ) -> [String] {
        switch installerType {
        case .msi:
            let logPath = logPath ?? "nancy-drew-install-log.txt"
            if attemptNumber == 0 {
                // Silent install with logging
                return ["/qn", "/l*", logPath, "/i", installerPath]
            } else {
                // Interactive install (still collect installer logs)
                return ["/l*", logPath, "/i", installerPath]
            }

        case .installShield:
            // Check for setup.iss file for silent install
            let driveCPath = WrappLayout(app: wrappPath).driveC
            let setupIssPath = driveCPath.appendingPathComponent(WrappLayout.installersFolder).appendingPathComponent("setup.iss")

            if attemptNumber == 0 && fileManager.fileExists(atPath: setupIssPath.path) {
                // Use AutoIt for games that don't exit properly in non-interactive mode
                if gameInfo.doesNotExitInNonInteractiveMode {
                    // Return empty array - AutoIt will be handled specially in runInstaller
                    return []
                } else {
                    // Silent install with .iss response file
                    let windowsIssPath = "C:\\nancy-drew-installer\\setup.iss"
                    return ["/s", "/sms", "/f1\(windowsIssPath)"]
                }
            } else {
                // Interactive install with record mode
                return ["/r"]
            }

        case .innoSetup:
            let log = logPath.map { ["/LOG=\($0)"] } ?? []
            if attemptNumber == 0 {
                // Very silent install
                return ["/verysilent", "/norestart"] + log
            } else {
                // Interactive install
                return log
            }

        case .unknown:
            // No special arguments
            return []
        }
    }

    // MARK: - Executable Discovery

    /// Find installer executable in directory: `preferred`, the program the
    /// person chose when the disc had no installer by name, when it's there.
    private func findInstallerExecutable(in directory: URL, preferring preferred: String? = nil) throws -> String {
        if let preferred {
            let chosen = directory.appendingPathComponent(preferred)
            if fileManager.fileExists(atPath: chosen.path) {
                logger.notice("Using the installer chosen for this disc: \(preferred)")
                return chosen.path
            }
            logger.warning("The installer chosen for this disc, \(preferred), isn't in \(directory.path)")
        }

        // The same lookup that recognised the game, so the installer run is
        // the one detection found (`GameDetector.installerLookup`).
        logger.notice("Searching for installer executable in: \(directory.path)")
        switch try GameDetector.installerLookup(in: directory) {
        case .recognised(let name):
            return directory.appendingPathComponent(name).path
        case .unrecognised(let programs):
            guard let first = programs.first else { break }
            logger.notice("No installer by name; running the first program there: \(first)")
            return directory.appendingPathComponent(first).path
        case .none:
            break
        }
        logger.critical("ERROR: No installer executable found in \(directory.path)")
        logger.notice("Expected to find .msi, setup.exe, install.exe, or any .exe file")
        throw WrappBuildError.installerNotFound
    }

    /// Find executable files in directory: a walk over the whole of drive C,
    /// so run it off the main thread.
    private nonisolated static func findExecutableFiles(in directory: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var executables = Set<String>()

        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "exe" {
            executables.insert(fileURL.path)
        }

        return executables
    }

    /// Find the game executable after installation
    private func findGameExecutable(
        before: Set<String>,
        after: Set<String>,
        expectedPath: String?,
        driveCPath: URL
    ) throws -> URL {
        logger.notice("=== Searching for game executable ===")

        // Find new executables
        let newExes = after.subtracting(before)
        logger.notice("Number of executables before installation: \(before.count)")
        logger.notice("Number of executables after installation: \(after.count)")
        logger.notice("Number of new executables found: \(newExes.count)")

        if newExes.isEmpty {
            logger.warning("WARNING: No new executables were created during installation")
            logger.notice("First few existing executables:")
            for (index, exe) in after.prefix(5).enumerated() {
                logger.notice("  \(index + 1). \(exe)")
            }
        } else {
            logger.notice("New executables found:")
            for (index, exe) in newExes.enumerated() {
                logger.notice("  \(index + 1). \(exe)")
            }
        }

        // Check if expected path exists
        if let expectedPath = expectedPath {
            let fullPath = driveCPath.appendingPathComponent(expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            logger.notice("Looking for expected game executable at: \(fullPath.path)")
            if fileManager.fileExists(atPath: fullPath.path) {
                logger.notice("✓ Found game executable at expected path")
                return fullPath
            } else {
                logger.notice("✗ Expected game executable not found at: \(fullPath.path)")
            }
        } else {
            logger.notice("No expected game executable path provided in game info")
        }

        // Look for game.exe or similar
        logger.notice("Searching for 'game.exe' in new executables...")
        for exePath in newExes {
            let url = URL(fileURLWithPath: exePath)
            let name = url.lastPathComponent.lowercased()
            if name == "game.exe" {
                logger.notice("✓ Found game.exe at: \(exePath)")
                return url
            }
        }
        logger.notice("✗ No 'game.exe' found in new executables")

        // Otherwise the likeliest of what's new: never an uninstaller or a
        // setup program, and of the rest the largest (a game's exe dwarfs its
        // helpers), so the choice is the same every time.
        if let likeliest = Self.likeliestGameExe(among: newExes) {
            logger.notice("Using the likeliest new executable: \(likeliest.path)")
            return likeliest
        }

        logger.critical("ERROR: Could not determine game executable")
        logger.notice("Search criteria:")
        logger.notice("  - Expected path: \(expectedPath ?? "none")")
        logger.notice("  - drive_c path: \(driveCPath.path)")
        logger.notice("  - New executables: \(newExes.count)")

        throw WrappBuildError.gameExecutableNotFound
    }
}

extension GameInstallerRunner {
    /// Names of the programs an installer leaves beside a game that aren't it.
    private static let notTheGame = ["unins", "uninst", "setup", "install", "update", "patch", "readme", "dxsetup", "vcredist"]

    /// The new executable most likely to be the game, or nil if every one
    /// is an uninstaller, a setup program or the like.
    nonisolated static func likeliestGameExe(among paths: some Collection<String>) -> URL? {
        let candidates = paths.map { URL(fileURLWithPath: $0) }.filter { url in
            let name = url.lastPathComponent.lowercased()
            return !notTheGame.contains { name.hasPrefix($0) }
        }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return candidates.max { lhs, rhs in
            let (left, right) = (size(lhs), size(rhs))
            return left != right ? left < right : lhs.path > rhs.path
        }
    }
}
