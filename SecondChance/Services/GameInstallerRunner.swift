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
import WrappBuilder
import Logging
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.Wine")

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

    let fileManager = FileManager.default
    let catalog: GamePatchCatalog
    nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner")
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
        chooseGameProgram: ([String]) async throws -> String,
        automation: URL? = nil,
        creates: String? = nil
    ) async throws -> (gameExePath: String, installerDir: String) {
        let driveCPath = WrappLayout(app: wrappPath).driveC

        // Find installer executable
        let installerExe: String
        let lent = try installerPath.map { try lendFolder(of: $0, at: wrappPath) } ?? false
        defer { if lent { Wine(wrapp: wrappPath).drives.takeBack() } }
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
            let plan = installerPlan(
                installerPath: installerExe,
                installerType: installerType,
                wrappPath: wrappPath,
                attemptNumber: 0,
                automation: automation
            )
            logger.notice("DEBUG: Would have run: \(plan.description)")
            if let underlyingCommand = plan.automatedDescription {
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
                        automation: automation,
                        attemptNumber: attempt
                    )
                }
                await bus.publishWrappBuild(.instructions(nil))

                // Get list of exe files after installation
                let exesAfter = await Blocking.run { Self.findExecutableFiles(in: driveCPath) }

                // Try to find the game executable
                do {
                    gameExe = try await findGameExecutable(
                        before: exesBefore,
                        after: exesAfter,
                        expectedPath: creates,
                        driveCPath: driveCPath,
                        choose: chooseGameProgram
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
        var relativePath = gameExe.path(relativeTo: driveCPath)
        if let creates {
            relativePath = String(try linkExpected(creates, toFound: gameExe, driveC: driveCPath).dropFirst())
        }

        // Determine the installer directory (disk-combined or disk-1)
        let installerDir = installerDirectoryPath(in: driveCPath)

        await bus.publishWrappBuild(.gameExeDetected(path: "/" + relativePath, gameInfo: gameInfo))

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

        let lent = try lendFolder(of: launcher, at: wrappPath)
        defer { if lent { Wine(wrapp: wrappPath).drives.takeBack() } }
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
        source: WrappSource
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
    func installerDirectoryPath(in driveCPath: URL) -> String {
        guard let directory = installerDirectory(in: driveCPath) else { return "/" + WrappLayout.installersFolder }
        return "/\(WrappLayout.installersFolder)/\(directory.lastPathComponent)"
    }

    // MARK: - AutoIt Automation

    /// Where the step's AutoIt script is put in the prefix, as Wine names it.
    nonisolated static let automationScriptPath = "C:\\automation.au3"

    /// Copy AutoIt and the step's script (`--automation`) into the prefix.
    private func setupAutoItForInstall(in wrappPath: URL, script: URL) async throws {
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

        // The script the step names, which clicks where the installer stops.
        guard fileManager.fileExists(atPath: script.path) else { throw WrappBuildError.autoItScriptNotFound }
        let scriptDestPath = driveCPath.appendingPathComponent("automation.au3")
        if fileManager.fileExists(atPath: scriptDestPath.path) {
            try fileManager.removeItem(at: scriptDestPath)
        }
        try fileManager.copyItem(at: script, to: scriptDestPath)
        logger.notice("✅ Copied \(script.lastPathComponent) to drive_c")
    }

    /// Remove AutoIt files from Wine prefix after installation
    private func cleanupAutoItAfterInstall(in wrappPath: URL) {
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let autoitDir = driveCPath.appendingPathComponent("autoit")
        let scriptPath = driveCPath.appendingPathComponent("automation.au3")

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

    /// Host and Windows paths for an installer's own log file.
    struct InstallerLogFile {
        let format: InstallerLogFormat
        let hostPath: URL
        let windowsPath: String
    }

    /// Build a unique installer log file path in the Wine prefix temp directory.
    func prepareInstallerLog(in wrappPath: URL, format: InstallerLogFormat) throws -> InstallerLogFile {
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

    /// The plan for one attempt at running the installer (`InstallerPlan`).
    private func installerPlan(
        installerPath: String,
        installerType: InstallerType,
        wrappPath: URL,
        attemptNumber: Int,
        automation: URL?,
        logPath: String? = nil
    ) -> InstallerPlan {
        InstallerPlan(installerPath: installerPath, type: installerType, attempt: attemptNumber,
                      hasAnswerFile: hasAnswerFile(in: wrappPath),
                      automationScript: automation == nil ? nil : Self.automationScriptPath,
                      driveC: WrappLayout(app: wrappPath).driveC, logPath: logPath)
    }

    /// Whether the disc's InstallShield answer file was copied in.
    private func hasAnswerFile(in wrappPath: URL) -> Bool {
        let setupIss = WrappLayout(app: wrappPath).installers.appendingPathComponent("setup.iss")
        return fileManager.fileExists(atPath: setupIss.path)
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
        automation: URL?,
        attemptNumber: Int
    ) async throws -> InstallerType {
        let installerType = await detectInstallerType(installerPath)
        let installerTypeDesc = String(describing: installerType)
        logger.notice("Installer type: \(installerTypeDesc)")
        await bus.publishWrappBuild(.installerResolved(exePath: installerPath, type: installerType))

        // Diagnostic logging for the AutoIt decision (the decision itself is
        // made once, in `InstallerPlan`).
        logger.debug("Attempt number: \(attemptNumber)")
        let driveCPath = WrappLayout(app: wrappPath).driveC
        let setupIssExists = hasAnswerFile(in: wrappPath)
        logger.debug("Setup.iss exists: \(setupIssExists)")
        logger.debug("AutoIt script: \(automation?.lastPathComponent ?? "none")")

        let installerLog = InstallerLogFormat(installerType)
            .map { try? prepareInstallerLog(in: wrappPath, format: $0) } ?? nil
        if let installerLog {
            logger.notice("\(installerLog.format.name) install log file: \(installerLog.hostPath.path)")
        }

        // Build and print the command that will be executed
        let plan = installerPlan(
            installerPath: installerPath,
            installerType: installerType,
            wrappPath: wrappPath,
            attemptNumber: attemptNumber,
            automation: automation,
            logPath: installerLog?.windowsPath
        )
        logger.notice("Running: \(plan.description)")
        if let underlyingCommand = plan.automatedDescription {
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
            logStreamer = try startInstallerLogStreaming(installerLog, onLine: stallWatch.map { watch in { @Sendable _ in watch.sawOutput() } })
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
        let usesAutoIt = plan.usesAutoIt
        if usesAutoIt, let automation {
            try await setupAutoItForInstall(in: wrappPath, script: automation)
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
        let interactive = plan.runsInteractively
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
        let program: WineCommand = plan.usesStart
            ? .start(plan.program, plan.arguments)
            : .program(plan.program, plan.arguments)
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
    func waitForInstallerProcesses(at wrappPath: URL, releasing desktop: WineDesktop?, timeout: TimeInterval?,
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
    func retryingIfNoDisplay<T>(
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

    /// Lend `file`'s folder to Wine as a drive (`WineDrives.lend`) when the
    /// file is outside the prefix's C: drive, as a downloaded installer is,
    /// and say whether it did: the prefix has no drive showing the whole Mac,
    /// so Wine couldn't otherwise run it.
    func lendFolder(of file: URL, at wrappPath: URL) throws -> Bool {
        let driveC = WrappLayout(app: wrappPath).driveC.standardizedFileURL.path
        guard !file.standardizedFileURL.path.hasPrefix(driveC + "/") else { return false }
        let folder = file.deletingLastPathComponent()
        try Wine(wrapp: wrappPath).drives.lend(folder)
        logger.notice("\(WineDrives.lentLetter.uppercased()): shows \(folder.path) while \(file.lastPathComponent) runs")
        return true
    }

    /// Start Wine's desktop before an installer or patcher runs, so it isn't
    /// left to Wine's 10-second on-demand start ("The explorer process failed
    /// to start", which once failed Stay Tuned's patch). See `WineDesktop`.
    /// A program run without it is sure to fail: AutoIt then can't open its
    /// window and exits 0 without having run its script.
    func startDesktop(at wrappPath: URL) async -> WineDesktop? {
        await WineDesktop.start(Wine(wrapp: wrappPath), logger: logger, outputLogger: wineOutputLogger)
    }

    /// Throw `failure(reason)` unless the installer's log records it
    /// finishing; log the verdict either way.
    func checkInstallerLog(_ log: InstallerLogFile, failure: (String) -> Error) throws {
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
    /// silently (`InstallerPlan.runsInteractively`), for a game AutoIt
    /// doesn't drive.
    func runsInteractively(installerType: InstallerType, attemptNumber: Int, setupIssExists: Bool) -> Bool {
        InstallerPlan(installerPath: "", type: installerType, attempt: attemptNumber, hasAnswerFile: setupIssExists).runsInteractively
    }

    /// The progress screen's instructions while an unattended install has
    /// gone quiet with one of its windows on screen.
    static let installerQuestionInstructions =
        "The game's installer is asking something in its own window. Answer it there, and the install will carry on."

    /// The progress screen's step while the stalled unattended install gives
    /// way to the installer's own window.
    static let stalledInstallSubstep = "The install got stuck, so the installer is opening for you to finish it"
    /// Shown when installing by itself didn't work for any other reason.
    static let retryingInstallSubstep = "Installing by itself didn't work, so the installer is opening for you to finish it"

    /// The progress screen's instructions while an installer's own window is
    /// up for the person to click through.
    static func interactiveInstallInstructions(for gameInfo: GameInfo) -> String {
        let tips = gameInfo.installInstructions ?? GameInfo.defaultInstallInstructions
        return "The game's installer has opened in its own window. Click through it to install the game. \(tips)"
    }

    /// The installer's own arguments for an attempt (`InstallerPlan`).
    func getInstallerArguments(
        installerPath: String,
        installerType: InstallerType,
        gameInfo: GameInfo,
        wrappPath: URL,
        attemptNumber: Int,
        logPath: String? = nil
    ) -> [String] {
        installerPlan(installerPath: installerPath, installerType: installerType,
                      wrappPath: wrappPath, attemptNumber: attemptNumber, automation: nil, logPath: logPath).installerArguments
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

    /// New programs an install left, likeliest to be the game first.
    /// Uninstallers, setup programs and the like go last. Of the rest, the
    /// shallowest first, as a game's own program sits at the top of the
    /// folder it was installed in (the one the person picked, if the
    /// installer asked) and its helpers in folders beneath; then the largest,
    /// as a game's program dwarfs its helpers; then by name, so the order
    /// never depends on how the disk lists them.
    nonisolated static func rankedGamePrograms(_ paths: Set<String>) -> [URL] {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let ranked = paths.map { URL(fileURLWithPath: $0) }.map { (url: $0, size: size($0)) }.sorted { first, second in
            let (firstOut, secondOut) = (isNotTheGame(first.url), isNotTheGame(second.url))
            if firstOut != secondOut { return secondOut }
            let (firstDepth, secondDepth) = (first.url.pathComponents.count, second.url.pathComponents.count)
            if firstDepth != secondDepth { return firstDepth < secondDepth }
            if first.size != second.size { return first.size > second.size }
            return first.url.path.localizedStandardCompare(second.url.path) == .orderedAscending
        }
        return ranked.map(\.url)
    }

    /// Find the game executable after installation
    private func findGameExecutable(
        before: Set<String>,
        after: Set<String>,
        expectedPath: String?,
        driveCPath: URL,
        choose: ([String]) async throws -> String
    ) async throws -> URL {
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

        // Otherwise one of the new programs: the only likely one, or the
        // person's choice when there are several
        let ranked = Self.rankedGamePrograms(newExes)
        let likely = ranked.filter { !Self.isNotTheGame($0) }
        if likely.count == 1, let only = likely.first {
            logger.notice("Using the only likely new executable: \(only.path)")
            return only
        }
        if ranked.count == 1, let only = ranked.first {
            logger.notice("Using the only new executable: \(only.path)")
            return only
        }
        if !ranked.isEmpty {
            let names = ranked.map { Self.windowsPath(of: $0, driveC: driveCPath) }
            let chosen = try await choose(names)
            guard let index = names.firstIndex(of: chosen) else { throw WrappBuildError.gameExecutableNotFound }
            logger.notice("Using the chosen executable: \(ranked[index].path)")
            return ranked[index]
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
    nonisolated private static let notTheGame = ["unins", "uninst", "setup", "install", "update", "patch", "readme", "dxsetup", "vcredist"]

    /// Whether a program is an uninstaller, a setup program or the like,
    /// by its name.
    nonisolated static func isNotTheGame(_ program: URL) -> Bool {
        let name = program.lastPathComponent.lowercased()
        return notTheGame.contains { name.hasPrefix($0) }
    }
}

extension GameInstallerRunner {
    /// The step's `--creates` (`/Nancy Drew/Game/Game.exe`, from the root of
    /// C:), made to name what the installer actually made: people have
    /// other versions of a disc than ours, which may install elsewhere or
    /// name the program differently. Where the folder differs, the expected
    /// one becomes a link to the folder the game went to; where the
    /// program's name differs too, the expected program a link to the one
    /// found. Nothing after the install needs to know. The links are
    /// relative, so they hold wherever the app is.
    func linkExpected(_ creates: String, toFound found: URL, driveC: URL) throws -> String {
        let expected = driveC.appendingPathComponent(creates.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard expected.standardizedFileURL.resolvingSymlinksInPath() != found.standardizedFileURL.resolvingSymlinksInPath() else {
            return creates
        }
        let expectedFolder = expected.deletingLastPathComponent()
        let foundFolder = found.deletingLastPathComponent()
        if expectedFolder.standardizedFileURL != foundFolder.standardizedFileURL {
            guard !fileManager.fileExists(atPath: expectedFolder.path) else {
                throw WrappBuildError.buildRecipeProblem(
                    "the installer put the game in \(foundFolder.path(relativeTo: driveC)), but \(creates) expects it in a folder that is there already")
            }
            try fileManager.createDirectory(at: expectedFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let relative = Self.relativePath(from: expectedFolder.deletingLastPathComponent(), to: foundFolder)
            try fileManager.createSymbolicLink(atPath: expectedFolder.path, withDestinationPath: relative)
            logger.notice("Linked \(expectedFolder.path(relativeTo: driveC)) to \(relative), where the installer put the game")
        }
        if expected.lastPathComponent != found.lastPathComponent, !fileManager.fileExists(atPath: expected.path) {
            try fileManager.createSymbolicLink(atPath: expected.path, withDestinationPath: found.lastPathComponent)
            logger.notice("Linked \(expected.lastPathComponent) to \(found.lastPathComponent), the program the installer made")
        }
        return creates
    }

    /// `target` relative to the folder `base`: `../Other/Game`.
    nonisolated static func relativePath(from base: URL, to target: URL) -> String {
        let from = base.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }
}

extension GameInstallerRunner {
    /// An install step's `--creates`, from the root of C:
    /// (`/Nancy Drew/Game/Game.exe`), checked to be in its `--into`, where
    /// the step says the game goes; nil for a step that names none.
    nonisolated static func expectedProgram(of step: PlannedStep) throws -> String? {
        guard let creates = step.option("creates") else { return nil }
        guard creates.hasPrefix("wine:C:/") else {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): --creates=\(creates) isn't on the C: drive")
        }
        if let into = step.option("into"), !creates.hasPrefix(into + "/") {
            throw WrappBuildError.buildRecipeProblem("\(step.origin): --creates=\(creates) isn't in --into=\(into)")
        }
        return String(creates.dropFirst("wine:C:".count))
    }
}
