//
//  GameInstallerRunner+Patches.swift
//  SecondChance
//
//  The official Her Interactive patches, as the steps `DO nancy-drew.patch`
//  expands to: a file fetched and put in the game, a patcher with a silent
//  mode run as an installer is, or a wizard driven by AutoIt. Each step
//  carries out what it says. See docs/game-patches.md.

import Foundation
import Logging
import SecondChanceKit
import SecondChanceReporting
import GameCatalog
import WrappBuilder

extension GameInstallerRunner {
    // MARK: - Game Patches

    /// Something that went wrong applying one patch. Every case is recoverable:
    /// the build continues without that patch unless the user says otherwise.
    enum GamePatchError: LocalizedError {
        case archiveMissing(String)
        case payloadMissing(payload: String, archive: String)
        case unzipFailed(String)
        case installerFailed(id: String, exitCode: Int32)
        case installerDidNotFinish(id: String, reason: String)
        case programFailed(id: String, exitCode: Int32)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .archiveMissing(let archive):
                return "The patch archive \(archive) was not bundled with Second Chance. It may have failed to download when Second Chance was built."
            case .payloadMissing(let payload, let archive):
                return "\(archive) did not contain the expected file \(payload)."
            case .unzipFailed(let archive):
                return "Could not unzip \(archive)."
            case .installerFailed(let id, let exitCode):
                return "The patch installer for \(id) exited with code \(exitCode)."
            case .installerDidNotFinish(let id, let reason):
                return "The patch installer for \(id) exited cleanly but didn't finish: \(reason)"
            case .programFailed(let id, let exitCode):
                return "\(id)'s program exited with code \(exitCode); its last lines above say where it stopped."
            case .timedOut(let id):
                return "\(id)'s program did not finish in time and was stopped."
            }
        }
    }

    // MARK: - The step's shapes

    /// `INSTALLER.RUN --patch`, its patcher put in place already by the
    /// runner's mounts: run as `runPatcher` runs it.
    func runPlacedPatcher(_ step: PlannedStep, wrappPath: URL) async throws {
        let id = step.name ?? step.instruction
        guard let program = step.arguments.first, let hostPath = hostLocation(program, in: wrappPath) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): INSTALLER.RUN --patch needs the patcher to run")
        }
        let winePath = Self.windowsPath(of: hostPath, driveC: WrappLayout(app: wrappPath).driveC)
        logger.notice("📦 Patch: \(id)")
        try await retryingIfNoDisplay(at: wrappPath, "\(id)'s patcher") {
            try await self.runSilentPatcher(id: id, hostPath: hostPath, winePath: winePath, at: wrappPath)
        }
    }

    // MARK: - Mounts

    /// A `--mount=` value's fields.
    nonisolated static func fields(of mount: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in mount.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            fields[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
        }
        return fields
    }

    // MARK: - Files

    /// A location in full form (planning wrote it so) as a path on this Mac,
    /// where its module places it: a `wine:C:/…` path in the prefix's drive
    /// C, a bare path in the app's `Contents/`.
    func hostLocation(_ location: String, in wrappPath: URL) -> URL? {
        WrappLayout(app: wrappPath).location(location, places: .shipped)
    }

    /// The Windows path (`C:\\…`) of a file inside the prefix's `drive_c`.
    ///
    /// Wine reads a path that starts with `/` as a Unix path, so cutting the
    /// `drive_c` prefix off alone leaves a path that names nothing.
    static func windowsPath(of file: URL, driveC: URL) -> String {
        let relative = file.standardizedFileURL.path.dropFirst(driveC.standardizedFileURL.path.count)
        return "C:" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    /// `C:/a/b` as `C:\a\b`; anything else as it is.
    nonisolated static func windowsStyle(_ argument: String) -> String {
        guard argument.range(of: #"^[A-Za-z]:([/\\].*)?$"#, options: .regularExpression) != nil else { return argument }
        return argument.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: - Running a patcher

    /// A patcher with a silent mode, run silently as its installer type
    /// allows, its success its exit code (and for Inno Setup, its log),
    /// given as long as any unattended install.
    private func runSilentPatcher(id: String, hostPath: URL, winePath: String, at wrappPath: URL) async throws {
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
        logger.notice("   → running \(hostPath.lastPathComponent) (\(installerType)) \(arguments.joined(separator: " "))")

        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        do {
            try await Wine(wrapp: wrappPath).run(.program(winePath, arguments), timeout: Self.unattendedInstallTimeout)
            try await waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: Self.unattendedInstallTimeout)
        } catch WineError.executionFailed(let code) {
            throw GamePatchError.installerFailed(id: id, exitCode: code)
        } catch WineError.timedOut {
            throw GamePatchError.timedOut(id)
        }
        if let installerLog {
            try checkInstallerLog(installerLog, failure: { GamePatchError.installerDidNotFinish(id: id, reason: $0) })
        }
    }

    /// Silent-install flags for a patch installer, by its family.
    ///
    /// Unlike the game installers there is no recorded `.iss` answer file for
    /// patches, so this is the generic flag set for each installer family.
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

extension GamePatch {
    /// A patch step's id that the catalogue doesn't list, for the question
    /// asked when it fails.
    nonisolated static func unlisted(id: String, game: String) -> GamePatch {
        GamePatch(id: id, game: game, title: id, url: "", archive: "", sha256: "", payload: "", action: .runInstaller,
                  destinationSubdirectory: nil, fixes: "", sourceUrl: "", automation: nil)
    }
}
