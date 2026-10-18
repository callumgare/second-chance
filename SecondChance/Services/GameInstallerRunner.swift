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

private nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.Wine")

/// Runs the game's own installer (setup.exe / .msi) inside the Wine prefix
/// and finds what it installed.
///
/// Build-aware: knows about installer types (MSI, InstallShield, Inno Setup),
/// silent/interactive strategies, and AutoIt automation. Delegates actual
/// execution to WineManager.
class GameInstallerRunner {
    static let shared = GameInstallerRunner()

    /// Ask the user whether to continue after a patch failed.
    ///
    /// Confirmation is injected via `patchFailureConfirmation` (default:
    /// continue without prompting). The GUI supplies an NSAlert-based
    /// handler through `WrappBuildInput.confirmPatchFailure`; headless runs
    /// default to continuing (a modal alert under a `.prohibited` activation
    /// policy is invisible and would hang the build forever).
    var patchFailureConfirmation: (@MainActor (String, Error) async -> Bool)?

    private let fileManager = FileManager.default
    private let wineManager: WineManager
    private let exiftool: ExiftoolService
    private let catalog: GamePatchCatalog
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner")
    let bus: EventBus<AppEvent>

    init(
        wineManager: WineManager = .shared,
        exiftool: ExiftoolService = .shared,
        catalog: GamePatchCatalog = .shared,
        bus: EventBus<AppEvent> = .app
    ) {
        self.wineManager = wineManager
        self.exiftool = exiftool
        self.catalog = catalog
        self.bus = bus
    }

    // MARK: - Game Installation

    /// Install game using Wine
    func installGameWithWine(
        wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource,
        installerPath: URL? = nil
    ) async throws -> (gameExePath: String, installerDir: String) {
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")

        // Find installer executable
        let installerExe: String
        if let installerPath = installerPath {
            // Direct installer path provided
            installerExe = installerPath.path
        } else {
            // Find setup.exe in disk directories
            let installerDir = try findInstallerDirectory(in: driveCPath)
            installerExe = try findInstallerExecutable(in: installerDir)
        }

        // Get list of exe files before installation
        let exesBefore = findExecutableFiles(in: driveCPath)

        // Check if debug mode is enabled to skip installer
        let skipInstaller = DebugSettings.shared.skipInstaller

        if skipInstaller {
            logger.notice("DEBUG: Skip installer enabled — using installer path as game exe: \(installerExe)")

            // Show what command would have been run using the same code path
            let installerType = detectInstallerType(installerExe)
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
        // click through it: never in strict mode, and never headless, where
        // it would wait for ever.
        let strictInstall = ProcessInfo.processInfo.environment["STRICT_INSTALL"] == "true"
        let headless = ProcessInfo.processInfo.environment["NON_INTERACTIVE"] == "true"
        let maxAttempts = (strictInstall || headless) ? 1 : 2
        if headless && !strictInstall {
            logger.notice("Headless build: no interactive installer retry if the silent install fails")
        }

        // Try installation with automatic/silent mode first
        var installAttempt = 0
        var gameExe: URL?
        var installerType = InstallerType.unknown

        while gameExe == nil && installAttempt < maxAttempts {
            logger.notice("🔄 Installation attempt \(installAttempt + 1) of \(maxAttempts)")
            do {
                // Run installer
                installerType = try await runInstaller(
                    at: wrappPath,
                    installerPath: installerExe,
                    gameInfo: gameInfo,
                    attemptNumber: installAttempt
                )

                // Get list of exe files after installation
                let exesAfter = findExecutableFiles(in: driveCPath)

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
                            try checkInstallFinished(
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
                    // Game executable not found
                    if installAttempt + 1 < maxAttempts {
                        logger.warning("Game exe not found after silent install — retrying with interactive mode...")
                        installAttempt += 1
                    } else {
                        // Strict mode or second attempt failed, throw the error
                        if strictInstall {
                            logger.critical("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                        } else if headless {
                            logger.critical("❌ Silent installation failed, and a headless build can't fall back to the interactive installer")
                        }
                        throw error
                    }
                }
            } catch {
                installAttempt += 1
                if installAttempt >= maxAttempts {
                    if strictInstall {
                        logger.critical("❌ STRICT_INSTALL mode: Silent installation failed, not falling back to interactive mode")
                    } else if headless {
                        logger.critical("❌ Silent installation failed, and a headless build can't fall back to the interactive installer")
                    } else {
                        logger.critical("❌ Installation failed after \(installAttempt) attempts")
                    }
                    throw error
                }

                logger.warning("Silent install failed: \(error) — retrying with interactive mode...")
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
        do {
            try await applyGamePatches(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                gameInstallDir: gameExe.deletingLastPathComponent(),
                source: source
            )
        } catch WrappBuildError.userCancelled {
            throw WrappBuildError.userCancelled
        } catch {
            logger.warning("⚠️  Failed to apply patches: \(error)")
        }

        return ("/" + relativePath, installerDir)
    }

    /// Install game using ScummVM (no actual installer needed - just returns disk path)
    func installGameWithScummVM(
        wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource
    ) async throws -> (gameExePath: String, installerDir: String) {
        // For ScummVM games, the "installation" is simply having the disk files available
        // The disk files were already copied by wrappBuilder.copyGameDisks()
        // We just need to return the path where the game files are located

        // ScummVM games don't need installation - they run directly from the disk files
        // The game files are located in SharedSupport/nancy-drew-installer/disk-1 (or disk-combined)

        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
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
        do {
            try await applyGamePatches(
                wrappPath: wrappPath,
                gameInfo: gameInfo,
                gameInstallDir: gameDir,
                source: source
            )
        } catch WrappBuildError.userCancelled {
            throw WrappBuildError.userCancelled
        } catch {
            logger.warning("⚠️  Failed to apply patches: \(error)")
        }

        return ("/" + relativePath, "/" + relativeInstallerDir)
    }

    // MARK: - Disk Directory Resolution

    /// Find the directory containing the installer: prefer disk-combined, else
    /// disk-1, else fail. Centralizes a lookup that was previously duplicated.
    private func findInstallerDirectory(in driveCPath: URL) throws -> URL {
        let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
        let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
        let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")

        if fileManager.fileExists(atPath: combinedDir.path) {
            logger.notice("Using combined disk directory")
            return combinedDir
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            logger.notice("Using disk-1 directory")
            return disk1Dir
        } else {
            logger.critical("Could not find disk directory — expected at \(disk1Dir.path) or \(combinedDir.path)")
            throw WrappBuildError.diskNotFound
        }
    }

    /// The installer directory as a Windows-style path relative to drive_c
    /// (e.g. "/nancy-drew-installer/disk-1").
    private func installerDirectoryPath(in driveCPath: URL) -> String {
        let installerBaseDir = driveCPath.appendingPathComponent("nancy-drew-installer")
        let combinedDir = installerBaseDir.appendingPathComponent("disk-combined")
        let disk1Dir = installerBaseDir.appendingPathComponent("disk-1")

        if fileManager.fileExists(atPath: combinedDir.path) {
            return "/nancy-drew-installer/disk-combined"
        } else if fileManager.fileExists(atPath: disk1Dir.path) {
            return "/nancy-drew-installer/disk-1"
        } else {
            return "/nancy-drew-installer"
        }
    }

    // MARK: - Game Patches

    /// How long a single patch installer gets before it is assumed to be
    /// sitting on a dialog that nobody can answer.
    private static let patchInstallerTimeout: TimeInterval = 180

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
    /// A failing patch never fails the build on its own: it routes through
    /// `confirmPatchFailure`, which continues by default.
    private func applyGamePatches(
        wrappPath: URL,
        gameInfo: GameInfo,
        gameInstallDir: URL,
        source: WrappSource
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

        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")

        logger.notice("🔧 Applying \(patches.count) patch(es) for '\(gameSlug)' (\(source.rawValue))...")

        for patch in patches {
            logger.notice("📦 Patch: \(patch.id) — \(patch.title)")
            do {
                let before = GameFileSnapshot(of: gameInstallDir)
                try await apply(
                    patch,
                    wrappPath: wrappPath,
                    driveCPath: driveCPath,
                    gameInstallDir: gameInstallDir
                )
                let changed = GameFileSnapshot(of: gameInstallDir).changes(since: before)
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
                logger.error("❌ Patch failed: \(patch.id): \(error.localizedDescription)")
                await bus.publishWrappBuild(.patchFailed(id: patch.id, message: error.localizedDescription))
                let continueInstall = await confirmPatchFailure(patchName: patch.title, error: error)
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

        try unzipPatchArchive(archiveURL, into: tempDir)

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
            try unzipPatchArchive(payload, into: destinationDir)
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
    private func unzipPatchArchive(_ archive: URL, into directory: URL) throws {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", archive.path, "-d", directory.path]
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
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
        if let automation = patch.automation {
            try await runAutomatedPatchInstaller(patch, script: automation, at: wrappPath, winePath: winePath)
            return
        }

        let installerType = detectInstallerType(hostPath.path)
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

        // runWine stops the prefix's wineserver on timeout, which is the only
        // thing that ends the Windows process.
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        let exitCode: Int32
        do {
            exitCode = try await wineManager.runWindowsExecutable(
                at: wrappPath,
                exePath: winePath,
                arguments: arguments,
                timeout: Self.patchInstallerTimeout
            )
        } catch WineError.timedOut {
            throw GamePatchError.timedOut(patch.id)
        }
        guard exitCode == 0 else {
            throw GamePatchError.installerFailed(id: patch.id, exitCode: exitCode)
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
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let scriptPath = try stageAutoIt(script: script, inDriveC: driveCPath)
        defer { removeAutoIt(script: scriptPath, inDriveC: driveCPath) }

        let scriptWinePath = Self.windowsPath(of: scriptPath, driveC: driveCPath)
        logger.notice("   → running \(patch.payload) through AutoIt (\(script).au3)")
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        let exitCode: Int32
        do {
            exitCode = try await wineManager.runWindowsExecutable(
                at: wrappPath,
                exePath: Self.windowsPath(of: driveCPath.appendingPathComponent("autoit/AutoIt3.exe"), driveC: driveCPath),
                // /ErrorStdOut: a script error is printed (and logged) rather than
                // shown in a message box nobody will close.
                arguments: ["/ErrorStdOut", scriptWinePath, winePath],
                timeout: Self.patchInstallerTimeout
            )
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
    private func stageAutoIt(script: String, inDriveC driveCPath: URL) throws -> URL {
        guard AutoItService.shared.isAvailable else {
            throw WrappBuildError.autoItNotAvailable
        }
        guard let source = Bundle.main.url(forResource: script, withExtension: "au3", subdirectory: "patch-automation") else {
            throw WrappBuildError.autoItScriptNotFound
        }
        let autoitDestDir = driveCPath.appendingPathComponent("autoit")
        if !fileManager.fileExists(atPath: autoitDestDir.path) {
            try fileManager.copyItem(at: AutoItService.shared.autoitDir, to: autoitDestDir)
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

    /// Route a patch-failure confirmation through the injected handler when
    /// present, otherwise continue without prompting (headless default —
    /// a modal alert under a `.prohibited` activation policy would be
    /// invisible and hang the build forever).
    @MainActor
    private func confirmPatchFailure(patchName: String, error: Error) async -> Bool {
        if let confirmation = patchFailureConfirmation {
            return await confirmation(patchName, error)
        }
        logger.notice("No patch-failure handler installed — continuing without patch '\(patchName)'")
        return true
    }

    // MARK: - AutoIt Automation

    /// Copy AutoIt and automation script to Wine prefix for installer automation
    private func setupAutoItForInstall(in wrappPath: URL) throws {
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")

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

        // Copy AutoIt directory
        try fileManager.copyItem(at: autoitSourceDir, to: autoitDestDir)
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
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
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
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let windowsTempDir = driveCPath.appendingPathComponent("windows/temp")
        try fileManager.createDirectory(at: windowsTempDir, withIntermediateDirectories: true)

        let fileName = "nancy-drew-install-\(UUID().uuidString).log"
        let hostPath = windowsTempDir.appendingPathComponent(fileName)
        fileManager.createFile(atPath: hostPath.path, contents: nil)

        return InstallerLogFile(
            format: format,
            hostPath: hostPath,
            windowsPath: "C:\\\\windows\\\\temp\\\\\(fileName)"
        )
    }

    /// Stream an installer log file line-by-line to a dedicated logger.
    private func startInstallerLogStreaming(_ log: InstallerLogFile) throws -> InstallerLogStreamer {
        let streamer = InstallerLogStreamer(logPath: log.hostPath, format: log.format)
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
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")
        let useAutoIt = installerType == .installShield &&
                       attemptNumber == 0 &&
                       fileManager.fileExists(atPath: setupIssPath.path) &&
                       gameInfo.doesNotExitInNonInteractiveMode

        if useAutoIt {
            let autoitArgs = [
                "C:\\\\installshield-custom-dialog-automate.au3",
                installerPath,
                gameInfo.title
            ]
            let underlyingCommand = installerType == .msi
                ? "msiexec \(args.joined(separator: " "))"
                : "wine start /wait \(installerPath) \(args.joined(separator: " "))"

            return InstallerCommand(
                exePath: "C:\\\\autoit\\\\AutoIt3.exe",
                arguments: autoitArgs,
                useStartCommand: false,
                commandDescription: "C:\\\\autoit\\\\AutoIt3.exe \(autoitArgs.joined(separator: " "))",
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
    func checkInstallFinished(gameDir: URL, installerType: InstallerType, driveCPath: URL) throws {
        let size = DirectorySize.measure(gameDir)
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
        let installerType = detectInstallerType(installerPath)
        let installerTypeDesc = String(describing: installerType)
        logger.notice("Installer type: \(installerTypeDesc)")
        await bus.publishWrappBuild(.installerResolved(exePath: installerPath, type: installerType))

        // Diagnostic logging for the AutoIt decision (the decision itself is
        // made once, inside buildInstallerCommand).
        logger.debug("Attempt number: \(attemptNumber)")
        let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")
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

        // Stream the installer's own log independently from Wine stdout/stderr.
        var logStreamer: InstallerLogStreamer?
        if let installerLog {
            logStreamer = try startInstallerLogStreaming(installerLog)
        }
        defer {
            if let logStreamer {
                logStreamer.stop()
            }
            if let installerLog, !DebugSettings.shared.debugMode {
                try? fileManager.removeItem(at: installerLog.hostPath)
            }
        }

        // Setup AutoIt if needed
        if command.underlyingCommandDescription != nil {
            try setupAutoItForInstall(in: wrappPath)
        }

        // Execute the installer command. The WineManager methods return the
        // Wine exit code (already logged) rather than throwing for non-zero
        // exits. An unattended attempt gets a timeout, since nobody will
        // notice it hanging; the interactive one is someone working through
        // a wizard, who can take as long as they like.
        let timeout = attemptNumber == 0 ? Self.unattendedInstallTimeout : nil
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        let exitCode: Int32
        if command.useStartCommand {
            exitCode = try await wineManager.runWindowsExecutableWithStart(
                at: wrappPath,
                exePath: command.exePath,
                arguments: command.arguments,
                timeout: timeout
            )
        } else {
            exitCode = try await wineManager.runWindowsExecutable(
                at: wrappPath,
                exePath: command.exePath,
                arguments: command.arguments,
                timeout: timeout
            )
        }

        // A non-zero exit code usually means the install failed. Throw so the
        // caller's silent→interactive retry logic can kick in.
        if exitCode != 0 {
            throw WineError.executionFailed(exitCode: exitCode)
        }

        try await waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: timeout)

        // A clean exit isn't proof the install finished: check that the
        // installer's own log says it did.
        if let installerLog {
            try checkInstallerLog(installerLog, failure: { WrappBuildError.installIncomplete(reason: $0) })
        }

        // Cleanup AutoIt if it was used (skip in debug mode to allow manual re-runs)
        if command.underlyingCommandDescription != nil {
            if DebugSettings.shared.debugMode {
                logger.notice("DEBUG: Keeping AutoIt files for manual re-run")
            } else {
                cleanupAutoItAfterInstall(in: wrappPath)
            }
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
    private func waitForInstallerProcesses(at wrappPath: URL, releasing desktop: WineDesktop?, timeout: TimeInterval?) async throws {
        desktop?.release()
        logger.notice("Waiting for the installer's remaining Wine processes to finish")
        try await wineManager.runWine(at: wrappPath, executable: "wineserver", arguments: ["-w"], timeout: timeout)
    }

    /// Start Wine's desktop before an installer or patcher runs, so it isn't
    /// left to Wine's 10-second on-demand start ("The explorer process failed
    /// to start", which once failed Stay Tuned's patch). See `WineDesktop`.
    /// A program run without it is sure to fail: AutoIt then can't open its
    /// window and exits 0 without having run its script.
    private func startDesktop(at wrappPath: URL) async -> WineDesktop? {
        let wine = WineEnvironment(appPath: wrappPath)
        let logger = self.logger
        return await Task.detached {
            WineDesktop.start(wine, logger: logger, outputLogger: wineOutputLogger)
        }.value
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
    func detectInstallerType(_ installerPath: String) -> InstallerType {
        let url = URL(fileURLWithPath: installerPath)

        // Check file extension first
        if url.pathExtension.lowercased() == "msi" {
            return .msi
        }

        // Try to extract metadata using exiftool to detect InstallShield/Inno Setup
        do {
            let metadata = try exiftool.getFileProperties(installerPath, properties: ["ProductName", "Comments"])
            logger.notice("🔍 Installer metadata: \(metadata)")
            let combined = (metadata["ProductName"] ?? "") + " " + (metadata["Comments"] ?? "")
            let lowercased = combined.lowercased()

            if lowercased.contains("installshield") {
                return .installShield
            } else if lowercased.contains("inno setup") {
                return .innoSetup
            }
        } catch {
            logger.warning("⚠️ Failed to detect installer type via exiftool: \(error)")
        }

        return .unknown
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
            let driveCPath = wrappPath.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
            let setupIssPath = driveCPath.appendingPathComponent("nancy-drew-installer/setup.iss")

            if attemptNumber == 0 && fileManager.fileExists(atPath: setupIssPath.path) {
                // Use AutoIt for games that don't exit properly in non-interactive mode
                if gameInfo.doesNotExitInNonInteractiveMode {
                    // Return empty array - AutoIt will be handled specially in runInstaller
                    return []
                } else {
                    // Silent install with .iss response file
                    let windowsIssPath = "C:\\\\nancy-drew-installer\\\\setup.iss"
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

    /// Find installer executable in directory
    private func findInstallerExecutable(in directory: URL) throws -> String {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )

        logger.notice("Searching for installer executable in: \(directory.path)")

        // First look for .msi files
        for file in contents {
            if file.pathExtension.lowercased() == "msi" {
                return file.path
            }
        }

        // Then look for setup.exe
        for file in contents {
            let name = file.lastPathComponent.lowercased()
            if name == "setup.exe" {
                return file.path
            }
        }

        // Then look for install.exe
        for file in contents {
            let name = file.lastPathComponent.lowercased()
            if name == "install.exe" {
                return file.path
            }
        }

        // Look for any other .exe files
        let exeFiles = contents.filter { $0.pathExtension.lowercased() == "exe" }

        if let exe = exeFiles.first {
            return exe.path
        }

        logger.critical("ERROR: No installer executable found!")
        logger.notice("Expected to find .msi, setup.exe, install.exe, or any .exe file")
        logger.notice("Found \(contents.count) files/folders:")
        for file in contents {
            logger.notice("  - \(file.lastPathComponent)")
        }
        throw WrappBuildError.installerNotFound
    }

    /// Find executable files in directory
    private func findExecutableFiles(in directory: URL) -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var executables = Set<String>()

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "exe" {
                executables.insert(fileURL.path)
            }
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

        // Return first new executable
        if let first = newExes.first {
            logger.notice("Using first new executable as fallback: \(first)")
            return URL(fileURLWithPath: first)
        }

        logger.critical("ERROR: Could not determine game executable")
        logger.notice("Search criteria:")
        logger.notice("  - Expected path: \(expectedPath ?? "none")")
        logger.notice("  - drive_c path: \(driveCPath.path)")
        logger.notice("  - New executables: \(newExes.count)")

        throw WrappBuildError.gameExecutableNotFound
    }
}


/// Which installer log `InstallerLogStreamer` is following.
nonisolated enum InstallerLogFormat: Sendable {
    case msi
    case inno

    /// Nil for installers whose log Second Chance doesn't read.
    init?(_ installerType: InstallerType) {
        switch installerType {
        case .msi: self = .msi
        case .innoSetup: self = .inno
        case .installShield, .unknown: return nil
        }
    }

    var name: String {
        switch self {
        case .msi: return "MSI"
        case .inno: return "Inno Setup"
        }
    }
}

/// Follows an installer's own log (`tail -F`) into the log. msiexec writes a
/// line or two for every file it installs — 97% of the lines in a run that
/// installed several games — and Inno Setup four, so those go in at debug,
/// and the lines that say how the install went (failed actions, errors, the
/// final verdict) at notice or error. `stop()` logs a one-line summary.
nonisolated final class InstallerLogStreamer: @unchecked Sendable {
    private let logPath: URL
    private let format: InstallerLogFormat
    private let process = Process()
    private let logger: Logger
    private let lock = NSLock()
    private var lines = 0
    private var files = 0
    private var errors = 0

    init(logPath: URL, format: InstallerLogFormat) {
        self.logPath = logPath
        self.format = format
        let suffix = format == .msi ? "msi-log" : "inno-log"
        self.logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner.\(suffix)")
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "+1", "-F", logPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let format = format
        ProcessLineLogger.attach(
            to: pipe, logger: logger, level: .debug,
            levelFor: { Self.notableLevel(of: $0, format: format) ?? .debug },
            onLine: { [weak self] line in self?.count(line) }
        )
        try process.run()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let (lines, files, errors) = lock.withLock { (self.lines, self.files, self.errors) }
        logger.notice("\(format.name) log: \(lines) lines, \(files) files installed, \(errors) error line\(errors == 1 ? "" : "s")")
    }

    /// The level a line deserves beyond the debug copy it already got.
    static func notableLevel(of line: String, format: InstallerLogFormat) -> Logger.Level? {
        switch format {
        case .msi:
            if line.contains("Return value 3") || line.hasPrefix("Error ") || line.contains("Installation failed")
                || line.contains("-- Installation operation failed") {
                return .error
            }
            if line.contains("Installation completed successfully") || line.contains("-- Installation operation completed")
                || line.hasPrefix("MSI (") && line.contains("Product:") || line.contains(": INSTALL. Return value") {
                return .notice
            }
        case .inno:
            // Lines start with a timestamp: "2026-10-16 20:25:22.993   …".
            if line.contains("Exception message:") || line.contains("Installation process failed")
                || line.contains("Fatal exception") || line.contains("Setup is aborting") {
                return .error
            }
            if line.contains(InstallCompletion.innoSuccessLine) || line.contains("Setup version: ")
                || line.contains("Original Setup EXE: ") {
                return .notice
            }
        }
        return nil
    }

    private func count(_ line: String) {
        let isFile = switch format {
        case .msi: line.hasPrefix("File: ") && line.contains("Size:")
        case .inno: line.contains("Successfully installed the file.")
        }
        let isError = Self.notableLevel(of: line, format: format) == .error
        lock.withLock {
            lines += 1
            if isFile { files += 1 }
            if isError { errors += 1 }
        }
    }
}

/// The files under a game directory, by size and modification date, so a
/// patch's effect can be logged. Archive extraction keeps a file's original
/// date, so a file a patch adds shows up as new rather than as newer.
struct GameFileSnapshot {
    private var files: [String: (size: Int, modified: Date)] = [:]

    init(of directory: URL, fileManager: FileManager = .default) {
        let root = directory.resolvingSymlinksInPath().path
        guard let walker = fileManager.enumerator(
            at: directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            files[relative] = (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    /// Paths added, changed or removed since `earlier`, each marked `+`, `~` or `-`.
    func changes(since earlier: GameFileSnapshot) -> [String] {
        var result: [String] = []
        for (path, now) in files {
            if let then = earlier.files[path] {
                if then.size != now.size || then.modified != now.modified { result.append("~\(path)") }
            } else {
                result.append("+\(path)")
            }
        }
        for path in earlier.files.keys where files[path] == nil {
            result.append("-\(path)")
        }
        return result.sorted { $0.dropFirst() < $1.dropFirst() }
    }
}
