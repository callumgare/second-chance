//
//  GameInstallerRunner+Patches.swift
//  SecondChance
//
//  The official Her Interactive patches, applied once the game is installed:
//  which apply, unpacking each, and running or copying it into the game.
//  See docs/game-patches.md.

import Foundation
import Logging
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

extension GameInstallerRunner {
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

        logger.notice("🔧 Applying \(patches.count) patch(es) for '\(gameSlug)' (\(source.rawValue))...")

        for patch in patches {
            try await applyGamePatch(patch, wrappPath: wrappPath, gameInfo: gameInfo, gameInstallDir: gameInstallDir,
                                     source: source, confirmFailure: confirmFailure)
        }

        logger.notice("✅ Finished applying patches for '\(gameSlug)'")
    }

    /// Apply one patch, by its id in the catalogue: a step of a Wrappfile
    /// build (`DO nancy-drew.patch --id=…`). Nil when the catalogue has no
    /// such patch.
    func applyGamePatch(
        id: String,
        wrappPath: URL,
        gameInfo: GameInfo,
        gameInstallDir: URL,
        source: WrappSource,
        confirmFailure: PatchFailureConfirmation
    ) async throws -> Bool {
        guard let patch = catalog.allPatches(forGame: gameInfo.id).first(where: { $0.id == id }) else { return false }
        try await applyGamePatch(patch, wrappPath: wrappPath, gameInfo: gameInfo, gameInstallDir: gameInstallDir,
                                 source: source, confirmFailure: confirmFailure)
        return true
    }

    /// Apply one patch, reporting a failure and asking `confirmFailure`
    /// whether to carry on without it.
    private func applyGamePatch(
        _ patch: GamePatch,
        wrappPath: URL,
        gameInfo: GameInfo,
        gameInstallDir: URL,
        source: WrappSource,
        confirmFailure: PatchFailureConfirmation
    ) async throws {
        let driveCPath = WrappLayout(app: wrappPath).driveC
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
                game: gameInfo.id, source: source.rawValue, engine: gameInfo.composition.engineTag,
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

    /// Unpack one patch archive and apply its payload to the installed game.
    private func apply(
        _ patch: GamePatch,
        wrappPath: URL,
        driveCPath: URL,
        gameInstallDir: URL
    ) async throws {
        guard let archiveURL = DownloadCache.shipped(sha256: patch.sha256) else {
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

    /// Copy AutoIt and one of the nancy-drew module's scripts into the prefix, returning
    /// the script's host path.
    private func stageAutoIt(script: String, inDriveC driveCPath: URL) async throws -> URL {
        guard AutoItService.shared.isAvailable else {
            throw WrappBuildError.autoItNotAvailable
        }
        guard let source = NancyDrewModule.autoItScript(script) else {
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
}
