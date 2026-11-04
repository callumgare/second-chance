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

    /// Whether `step` is one this runs: one of the shapes `nancy-drew.patch`
    /// expands to.
    nonisolated static func isPatchStep(_ step: PlannedStep) -> Bool {
        switch (step.module, step.instruction) {
        case (nil, "ADD"): true
        case ("installer", "RUN"): step.has("patch")
        case (nil, "RUN"): true
        default: false
        }
    }

    /// Carry out a patch step as it says: an `ADD`, an `INSTALLER.RUN
    /// --patch`, or a `RUN` with `fetch` and `bind` mounts. A failure fails
    /// the build, unless the step says `--on-failure=ask`: then it's
    /// reported, and `confirmFailure` decides whether to carry on without
    /// it. So with `ask` this only throws to stop the build: `userCancelled`
    /// when the person chose to, or `CancellationError` when the build was
    /// cancelled.
    func runPatchStep(
        _ step: PlannedStep,
        plan: BuildPlan,
        wrappPath: URL,
        gameInfo: GameInfo,
        source: WrappSource,
        confirmFailure: PatchFailureConfirmation
    ) async throws {
        let id = step.name ?? step.instruction
        try Task.checkCancellation()
        let listed = catalog.allPatches(forGame: gameInfo.id).first { $0.id == id }
        logger.notice("📦 Patch: \(id)\(listed.map { " — \($0.title)" } ?? "")")
        do {
            switch (step.module, step.instruction) {
            case (nil, "ADD"):
                try await add(step, id: id, wrappPath: wrappPath)
            case ("installer", "RUN"):
                try await runPatcher(step, id: id, wrappPath: wrappPath)
            default:
                try await runMounted(step, id: id, plan: plan, wrappPath: wrappPath)
            }
            logger.notice("✅ Applied patch: \(id)")
            await bus.publishWrappBuild(.patchApplied(id: id))
        } catch {
            // Cancelling the build stops a patcher part way; that isn't
            // the patch failing.
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            guard step.option("on-failure") == "ask" else { throw error }
            logger.error("❌ Patch failed: \(id): \(error.localizedDescription)")
            await bus.publishWrappBuild(.patchFailed(id: id, message: error.localizedDescription))
            _ = FailureReporter.sendWithoutAsking(FailureReport(
                what: "Applying a game patch", kind: ErrorChain.identifier(error),
                game: gameInfo.id, source: source.rawValue, engine: gameInfo.composition.engineTag,
                tags: ["patch": id]
            ))
            let continueInstall = await confirmFailure(listed ?? GamePatch.unlisted(id: id, game: gameInfo.id), error)
            if continueInstall {
                logger.notice("⚠️  Continuing without patch: \(id)")
            } else {
                throw WrappBuildError.userCancelled
            }
        }
    }

    // MARK: - The step's shapes

    /// `ADD --checksum=sha256:<hash> --unpack=zip --member=<file> [--extract]
    /// <url> <folder>`: the archive, found in the download cache by its
    /// hash, unpacked, and its member put in the folder, or with
    /// `--extract`, what's in it (a self-extracting zip).
    private func add(_ step: PlannedStep, id: String, wrappPath: URL) async throws {
        guard step.arguments.count == 2, let folder = hostLocation(step.arguments[1], in: wrappPath) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): ADD needs a URL and a folder in the app")
        }
        let member = try await fetchMember(sha256: hash(step.option("checksum")), url: step.arguments[0],
                                           unpack: step.option("unpack"), member: step.option("member"))
        defer { try? fileManager.removeItem(at: member.deletingLastPathComponent()) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if step.has("extract") {
            // A self-extracting zip is a zip with an exe in front, which unzip
            // reads as it is. -o overwrites, so a rebuild is idempotent.
            try await unzip(member, into: folder)
            logger.notice("   → extracted \(member.lastPathComponent) into \(folder.lastPathComponent)")
        } else {
            let destination = folder.appendingPathComponent(member.lastPathComponent)
            // Overwrite rather than fail: rebuilding a wrapp must be idempotent.
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: member, to: destination)
            logger.notice("   → copied \(member.lastPathComponent) into \(folder.lastPathComponent)")
        }
    }

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

    /// `INSTALLER.RUN --patch --into=<folder> --mount=type=fetch,… <patcher>`:
    /// the patcher put where its mount says, run as an installer is (its
    /// type's silent switches) in `--into`, and taken away again. It looks
    /// for no game and makes no link.
    private func runPatcher(_ step: PlannedStep, id: String, wrappPath: URL) async throws {
        let layout = WrappLayout(app: wrappPath)
        guard let program = step.arguments.first, let hostPath = hostLocation(program, in: wrappPath) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): INSTALLER.RUN --patch needs the patcher to run")
        }
        let mounted = try await mount(step, plan: nil, wrappPath: wrappPath)
        defer { unmount(mounted) }
        if let into = step.option("into"), let folder = hostLocation(into, in: wrappPath),
           hostPath.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): this build runs a patcher in its own folder, not in \(into)")
        }
        let winePath = Self.windowsPath(of: hostPath, driveC: layout.driveC)
        try await retryingIfNoDisplay(at: wrappPath, "\(id)'s patcher") {
            try await self.runSilentPatcher(id: id, hostPath: hostPath, winePath: winePath, at: wrappPath)
        }
    }

    /// `RUN --mount=… <program> <arguments>` for a wizard with no silent
    /// mode: each mount put where its `target` says, the program run under
    /// Wine, its exit code the step's success, and the mounts taken away.
    private func runMounted(_ step: PlannedStep, id: String, plan: BuildPlan, wrappPath: URL) async throws {
        let layout = WrappLayout(app: wrappPath)
        guard let program = step.arguments.first, let hostPath = hostLocation(program, in: wrappPath) else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): RUN needs a program in the app's Wine")
        }
        let mounted = try await mount(step, plan: plan, wrappPath: wrappPath)
        defer { unmount(mounted) }
        let winePath = Self.windowsPath(of: hostPath, driveC: layout.driveC)
        // A program's own arguments are its text, but Windows programs want
        // `\` in a path the Wrappfile writes with `/`.
        let arguments = step.arguments.dropFirst().map(Self.windowsStyle)
        logger.notice("   → running \(([winePath] + arguments).joined(separator: " "))")
        let desktop = await startDesktop(at: wrappPath)
        defer { desktop?.release() }
        let exitCode: Int32
        do {
            do {
                try await Wine(wrapp: wrappPath).run(.program(winePath, Array(arguments)), timeout: Self.unattendedInstallTimeout)
                exitCode = 0
            } catch WineError.executionFailed(let code) {
                exitCode = code
            }
            // The program failing still waits for what it started.
            try await waitForInstallerProcesses(at: wrappPath, releasing: desktop, timeout: Self.unattendedInstallTimeout)
        } catch WineError.timedOut {
            throw GamePatchError.timedOut(id)
        }
        guard exitCode == 0 else { throw GamePatchError.programFailed(id: id, exitCode: exitCode) }
    }

    // MARK: - Mounts

    /// What a step's mounts put in the prefix, for `unmount` to take away.
    struct Mounted {
        var placed: [URL] = []
    }

    /// A step's `fetch` and `bind` mounts, each put at its `target`: a
    /// fetch's archive found by its hash and its member copied there; a
    /// bind's file (the bundle's or a module's, or AutoIt, which the
    /// installer module provides) copied there.
    private func mount(_ step: PlannedStep, plan: BuildPlan?, wrappPath: URL) async throws -> Mounted {
        var mounted = Mounted()
        do {
            for mount in step.options["mount"] ?? [] {
                let fields = Self.fields(of: mount)
                guard let target = fields["target"].flatMap({ hostLocation($0, in: wrappPath) }) else {
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): a mount's target isn't in the app: \(mount)")
                }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                switch fields["type"] {
                case "fetch":
                    let member = try await fetchMember(sha256: fields["sha256"] ?? "", url: fields["url"] ?? "",
                                                       unpack: fields["unpack"], member: fields["member"])
                    defer { try? fileManager.removeItem(at: member.deletingLastPathComponent()) }
                    try fileManager.copyItem(at: member, to: target)
                case "bind":
                    let source = fields["source"] ?? ""
                    let file: URL
                    if source == "module:installer:/autoit" {
                        guard AutoItService.shared.isAvailable else { throw WrappBuildError.autoItNotAvailable }
                        file = AutoItService.shared.autoitDir
                    } else if let found = plan?.file(source) {
                        file = found
                    } else {
                        throw WrappBuildError.buildRecipeProblem("\(step.origin): the plan has no file \(source)")
                    }
                    // AutoIt is tens of MB, so off the main thread.
                    try await Blocking.run { try FileManager.default.copyItem(at: file, to: target) }
                default:
                    throw WrappBuildError.buildRecipeProblem("\(step.origin): this build can't make a \(fields["type"] ?? "") mount")
                }
                mounted.placed.append(target)
            }
        } catch {
            unmount(mounted)
            throw error
        }
        return mounted
    }

    /// Take away what `mount` put in the prefix, so the app doesn't keep it.
    private func unmount(_ mounted: Mounted) {
        for item in mounted.placed.reversed() {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                logger.warning("Couldn't remove \(item.lastPathComponent) from the prefix: \(error.localizedDescription)")
            }
        }
    }

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

    /// A location in full form as a path on this Mac: a `wine:` path in the
    /// prefix's drive C, or a bare path in the app's `Contents/`.
    func hostLocation(_ location: String, in wrappPath: URL) -> URL? {
        let layout = WrappLayout(app: wrappPath)
        var path = location
        if path.hasPrefix("wine:") { path = String(path.dropFirst("wine:".count)) }
        if path.hasPrefix("C:/") { return layout.onDriveC(String(path.dropFirst(2))) }
        if location.hasPrefix("/") { return wrappPath.appendingPathComponent("Contents").appendingPathComponent(location) }
        return nil
    }

    /// `sha256:<hash>`'s hash.
    private func hash(_ checksum: String?) -> String {
        guard let checksum, checksum.hasPrefix("sha256:") else { return "" }
        return String(checksum.dropFirst("sha256:".count))
    }

    /// The archive whose hash is `sha256`, from the download cache, and with
    /// `unpack=zip` its `member`, unpacked into a folder of its own (the
    /// caller removes it).
    private func fetchMember(sha256: String, url: String, unpack: String?, member: String?) async throws -> URL {
        let name = URL(string: url)?.lastPathComponent ?? sha256
        guard let archive = DownloadCache.shipped(sha256: sha256) else {
            throw GamePatchError.archiveMissing(name)
        }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("patch-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard unpack == "zip", let member else {
            let copy = folder.appendingPathComponent(name)
            try fileManager.copyItem(at: archive, to: copy)
            return copy
        }
        try await unzip(archive, into: folder)
        // The step names the member exactly: the filenames follow no pattern
        // worth guessing at.
        let found = folder.appendingPathComponent(member)
        guard fileManager.fileExists(atPath: found.path) else {
            try? fileManager.removeItem(at: folder)
            throw GamePatchError.payloadMissing(payload: member, archive: name)
        }
        return found
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
        guard PathTypeRegistry.shortForm(of: argument) == .driveLetter else { return argument }
        return argument.replacingOccurrences(of: "/", with: "\\")
    }

    /// Extract an archive with `/usr/bin/unzip`.
    private func unzip(_ archive: URL, into directory: URL) async throws {
        let unzip = try await Process.output(of: "/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path])
        guard unzip.succeeded else {
            throw GamePatchError.unzipFailed(archive.lastPathComponent)
        }
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
