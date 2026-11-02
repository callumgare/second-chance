//
//  GameLauncher.swift
//  WrappTemplate
//
//  Game launching logic for Nancy Drew game wrappers

import Foundation
import Synchronization
import AppKit
import Logging
import os
import SecondChanceKit
import SecondChanceReporting
import GameCatalog

// MARK: - Game Launch Info

struct GameLaunchInfo {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let gameExeName: String?
    let gameExePath: String?  // Unix path to the game executable (for Wine games)
    /// What Wine runs, for a Wine game.
    var wineCommand: WineCommand?

    func formatLaunchCommand() -> String {
        let formattedCommand = formatShellCommand(executable: executable, arguments: arguments)
        if let workingDir = workingDirectory {
            return "cd \(shellQuote(workingDir)) && \(formattedCommand)"
        }
        return formattedCommand
    }
}

nonisolated func getGameLaunchInfo(_ config: GameConfig) -> GameLaunchInfo {
    let driveC = config.wine.driveC
    let gameExeUnixPath = WrappLayout.onDriveC(config.gameExePath, in: driveC).path
    let gameInstallerDirUnixPath = WrappLayout.onDriveC(config.gameInstallerDir, in: driveC).path

    let gameExeName = (gameExeUnixPath as NSString).lastPathComponent
    let gameExeDir = (gameExeUnixPath as NSString).deletingLastPathComponent
    switch config.gameEngine {
    case .wine, .wineSteam, .wineSteamSilent:
        // By name, from its own folder: games look for their files beside them.
        let command = WineCommand.start(gameExeName, unixPath: false, in: URL(fileURLWithPath: gameExeDir))
        let wine = config.wine
        return GameLaunchInfo(
            executable: command.executable(in: wine).path,
            arguments: command.processArguments,
            workingDirectory: gameExeDir,
            gameExeName: gameExeName,
            gameExePath: gameExeUnixPath,
            wineCommand: command
        )

    case .scummvm:
        // ScummVM game launch info
        let layout = WrappLayout(app: config.appPath)
        let resourcesPath = layout.resources
        let scummvmBinary = layout.scummvm.path
        let scummvmIni = resourcesPath.appendingPathComponent("scummvm.ini").path
        let savePath = config.appSupportPath.path
        let configPath = config.scummvmConfigPath.path

        let arguments = [
            "-f",                           // Fullscreen
            "--config=\(configPath)",       // User config file location
            "--initial-cfg=\(scummvmIni)",  // Configuration template to copy into configPath if there's no existing config
            "--path=\(gameInstallerDirUnixPath)",           // Game files location
            "--savepath=\(savePath)",       // Save files location
            "--auto-detect"                 // Automatically detect and start game
        ]

        return GameLaunchInfo(
            executable: scummvmBinary,
            arguments: arguments,
            workingDirectory: nil,
            gameExeName: nil,  // ScummVM doesn't have a separate game exe
            gameExePath: nil
        )
    }
}

// MARK: - Game Launcher

/// How a launch ended, for the wrapp to decide what to show.
enum LaunchOutcome: Equatable {
    /// The game was launched and has ended, with `exitCode`. `failed` when
    /// it ended badly (`GameLauncher.handleGameTermination`'s judgement),
    /// and `windowAppeared` whether its window was ever seen.
    case ended(exitCode: Int32, failed: Bool, windowAppeared: Bool)
    /// Nothing was started: the player chose to leave another game holding
    /// Steam, or quit first. No failure, and nothing to show.
    case notStarted
    /// Starting it failed, and the player has already been told (Steam's
    /// alert), so there is nothing more to show.
    case failedAndTold
}

class GameLauncher {
    private let config: GameConfig
    private let gameMonitor: GameMonitor
    private var currentProcess: Process?
    private var cleanupCompleted = false
    /// Captures a diagnostics bundle if a Wine game starts badly; nil for
    /// ScummVM. Made with the launcher, so a launch that stalls before the
    /// game starts (`captureDiagnostics`) can be captured too.
    private let startupDiagnostics: StartupDiagnostics?
    /// `startupDiagnostics`, once the game has been launched; nil before.
    private var diagnostics: StartupDiagnostics?
    /// What the launch thread, the main thread (a stuck launch's report)
    /// and the cleanup queue all reach, so behind a lock.
    private struct Shared {
        var desktop: WineDesktop?
        var steam: WrappSteam?
        var launchCounted = false
        var failureReport: FailureReport?
        var reportTask: Task<ReportOutcome, Never>?
    }
    private let shared = Mutex(Shared())
    /// The desktop `prepareDesktop` started, if it did. See `releaseDesktop`.
    private var desktop: WineDesktop? {
        get { shared.withLock { $0.desktop } }
        set { shared.withLock { $0.desktop = newValue } }
    }
    /// Steam, for a game that needs it running (`wine-steam*`).
    private var steam: WrappSteam? {
        get { shared.withLock { $0.steam } }
        set { shared.withLock { $0.steam = newValue } }
    }
    /// Whether the game's window was ever seen.
    private var windowAppeared = false
    /// The process whose window is the game's, from when that window appears
    /// until the game ends: what `bringGameForward` brings forward.
    private let gameWindowPid = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
    /// Told, once, when the game's Wine says it has no display driver
    /// (`NoDisplaySignal`): it will never show a window. Called from the
    /// thread reading its output.
    var onNoDisplay: (@Sendable (String) -> Void)?
    /// Told how far a quit has got, for the window that says the game is
    /// closing. Called from the cleanup's background queue.
    var onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?
    /// What the in-process helpers report from inside the game; Wine games only.
    private var helperReport: InProcessHelperReport?
    /// Judges whether a Wine game's exit was a quit; nil for ScummVM.
    private var quitCheck: GameQuitCheck?
    /// Set when the game's exit was no quit, but the game failing: it quit
    /// before it had started, or just after Wine reported an error.
    private(set) var unexpectedQuit: GameQuitCheck.Failure?
    /// The copy protection the game's .exe is wrapped in; Wine games only.
    private(set) var copyProtection: CopyProtection?
    /// The failure report for a run that ended badly, and its sending — for
    /// the error window to show, and for the wrapp to wait on before it exits.
    nonisolated var failureReport: FailureReport? { shared.withLock { $0.failureReport } }
    nonisolated var reportTask: Task<ReportOutcome, Never>? { shared.withLock { $0.reportTask } }
    private let cleanupQueue = DispatchQueue(label: "com.gamewrapper.cleanup")
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What Wine and the game print, and what ScummVM prints: categories of
    /// their own, so they read apart from the launcher's lines about them.
    private nonisolated let wineOutputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Wine")
    private nonisolated let scummvmOutputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.ScummVM")

    init(config: GameConfig, gameMonitor: GameMonitor) {
        self.config = config
        self.gameMonitor = gameMonitor
        startupDiagnostics = config.gameEngine.runsInWine
            ? StartupDiagnostics(gameSlug: config.gameSlug, gameTitle: config.gameTitle)
            : nil
    }

    /// Capture a diagnostics bundle now, whatever the launch is doing: when
    /// the loading window says it may have failed (`.stalled`), or when the
    /// wrapp is sent SIGUSR1 (`.manual`), from the signal's queue. Nothing
    /// for ScummVM.
    nonisolated func captureDiagnostics(_ reason: StartupDiagnostics.Reason) {
        startupDiagnostics?.captureNow(reason)
    }

    // MARK: - Bringing the game forward

    /// Whether the game's window is up, for `bringGameForward`.
    var hasGameWindow: Bool { gameWindowPid.withLock { $0 != nil } }

    /// Bring the game's window forward, for the wrapp being clicked in the
    /// Dock or chosen in Cmd-Tab: the wrapp is the game's app, though the
    /// game runs in a process of its own, with an icon of its own. Whether
    /// there was a game window to bring forward. Main thread, from the wrapp's own
    /// activation: only an app that is active may hand activation on.
    func bringGameForward() -> Bool {
        guard let pid = gameWindowPid.withLock({ $0 }),
              let game = NSRunningApplication(processIdentifier: pid), !game.isTerminated else { return false }
        NSApp.yieldActivation(to: game)
        let activated = game.activate(options: [.activateAllWindows])
        logger.notice("[Game Monitor] Bringing the game forward (PID \(pid)): \(activated ? "done" : "macOS refused")")
        return true
    }

    // MARK: - Cleanup and Shutdown

    /// Cleanup game and Wine processes when quitting
    /// Returns true if async cleanup is needed (caller should wait), false if cleanup is immediate
    func performCleanup(completion: @escaping @Sendable () -> Void) {
        logger.debug("[Cleanup/performCleanup] ENTERED performCleanup method")

        // Ensure cleanup only happens once
        cleanupQueue.sync {
            logger.debug("[Cleanup/performCleanup] Inside cleanupQueue.sync block")
            if cleanupCompleted {
                logger.debug("[Cleanup/performCleanup] Cleanup already completed, calling completion handler immediately")
                completion()
                return
            }
            logger.debug("[Cleanup/performCleanup] Setting cleanupCompleted = true")
            cleanupCompleted = true
        }
        logger.debug("[Cleanup/performCleanup] After cleanupQueue.sync block")

        logger.notice("[Cleanup] Starting cleanup process...")
        let onQuitStep = onQuitStep
        onQuitStep?(.closing)

        // Terminate the game process if it's still running
        if let process = currentProcess, process.isRunning {
            logger.notice("[Cleanup] Terminating game process (PID \(process.processIdentifier))...")
            process.terminate()
        }

        // For Wine games, we need to ensure wineserver is stopped
        if config.gameEngine.runsInWine {
            logger.debug("[Cleanup/performCleanup] Dispatching Wine server cleanup to background queue...")
            // .userInitiated: on a Mac with every core busy, .utility work
            // waits for seconds at a time, and the quit with it.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.logger.debug("[Cleanup/performCleanup] Inside Wine cleanup async block")
                guard let self = self else {
                    self?.logger.debug("[Cleanup/performCleanup] self is nil, calling completion handler")
                    completion()
                    return
                }

                // Steam would keep the Wine session alive, and its sign-in
                // has to be saved and taken out of the wrapp on the way out.
                // Briefly: the quit fallback kills everything after 15s, and
                // Steam has been seen to ignore -shutdown when it's stuck.
                if let steam = self.claimSteam() {
                    onQuitStep?(.closingSteam)
                    steam.finish(timeout: 8)
                }
                // The desktop's start.exe keeps the session going until it is
                // let go, so the session could never end by itself in its
                // grace period, and every quit waited it out.
                self.releaseDesktop()
                let server = self.config.wine.server
                self.logger.debug("[Cleanup/performCleanup] Shutting down Wine...")
                let periods = Self.quitPeriods()
                Blocking.wait {
                    await server.shutDown(gracePeriod: periods.grace, stopPeriod: periods.stop) { onQuitStep?(.init($0)) }
                }
                self.logger.debug("[Cleanup/performCleanup] Wine shut down")
                self.logger.debug("[Cleanup/performCleanup] About to call completion handler")
                completion()
                logger.debug("[Cleanup/performCleanup] Completion handler called")
            }
            logger.debug("[Cleanup/performCleanup] Wine cleanup dispatched, exiting performCleanup method")
        } else {
            // Non-Wine games, cleanup is immediate
            logger.debug("[Cleanup/performCleanup] Non-Wine game, cleanup is immediate")
            logger.debug("[Cleanup/performCleanup] About to call completion handler")
            completion()
            logger.debug("[Cleanup/performCleanup] Completion handler called, exiting performCleanup method")
        }
    }

    /// The wrapp is quitting (⌘Q, a signal): `performCleanup` has stopped the
    /// game, waits for Wine, and ends the wrapp once it's done.
    var isQuitting: Bool { cleanupQueue.sync { cleanupCompleted } }

    /// After the game has ended by itself: wait for the rest of its Wine
    /// session (explorer, Wine's services, the server) to finish, so the
    /// wrapp never quits leaving Wine running in the prefix. Nothing to wait
    /// for with ScummVM.
    func waitForWineToEnd() async {
        guard config.gameEngine.runsInWine else { return }
        // Generous: it ends by itself in seconds, more on a loaded Mac, and
        // only a session that is stuck reaches the kill.
        let server = config.wine.server
        let onQuitStep = onQuitStep
        let periods = Self.quitPeriods(grace: 30)
        await server.shutDown(gracePeriod: periods.grace, stopPeriod: periods.stop) { onQuitStep?(.init($0)) }
    }

    /// How long a quit waits at each step of `WineServer.shutDown`, and when
    /// the wrapp exits regardless after a signal (main.swift).
    nonisolated struct QuitPeriods {
        let grace: TimeInterval
        let stop: TimeInterval
        let heavyLoad: Bool
        /// Long enough for every step and the kill; 15 s on a Mac that isn't busy.
        var forcedExitAfter: TimeInterval { heavyLoad ? grace + 2 * stop + 5 : 15 }
    }

    /// Wine takes 4–5 s to end by itself with every core busy, against
    /// moments otherwise, so while the Mac is heavily loaded each of a quit's
    /// waits is `LoadingStage.heavyLoadFactor` times as long: fewer quits
    /// come to a kill, which can leave Wine's programs behind
    /// (`WineServer.kill`). Logs the longer wait when `announce`.
    nonisolated static func quitPeriods(grace: TimeInterval = 5, stop: TimeInterval = 5,
                                        announce: Bool = true) -> QuitPeriods {
        guard let load = SystemLoad.read(), load.isHeavy else {
            return QuitPeriods(grace: grace, stop: stop, heavyLoad: false)
        }
        let factor = LoadingStage.heavyLoadFactor
        if announce {
            Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
                .notice("[Wine Cleanup] The Mac is heavily loaded (\(load.summary)): giving Wine \(Int(grace * factor)) s to finish")
        }
        return QuitPeriods(grace: grace * factor, stop: stop * factor, heavyLoad: true)
    }

    // MARK: - Common Cleanup

    /// When the game was launched, for how long it ran.
    private var launchedAt = Date()
    /// Whether the game's own process was ever seen (always, for ScummVM).
    private var gameStarted = false
    /// The prefix's Documents, where the games keep their folders (a link to
    /// the wrapp's saves).
    private var documentsDirectory: URL {
        config.wine.documents
    }

    /// Log and report how the game ended; whether it ended badly.
    @discardableResult
    private func handleGameTermination(exitCode: Int32?, signal: Int32?, infoWindow: InfoWindowController?) -> Bool {
        let ran = SubprocessWatch.duration(Date().timeIntervalSince(launchedAt))
        // The wrapp stopping the game on its way out (Cmd-Q, a SIGTERM to the
        // wrapp) is a quit, not a failure, whatever signal the game got.
        if cleanupQueue.sync(execute: { cleanupCompleted }) {
            logger.notice("■ Game stopped after \(ran), because the wrapp is quitting")
            // The player quit a game that was running: it worked.
            if gameStarted && diagnostics?.hasSeenWindow != false {
                recordLaunch(outcome: SuccessReport.ok)
            }
            infoWindow?.close()
            logger.notice("[Game Launcher] Game has terminated, returning control to app lifecycle manager")
            return false
        }
        // Only Wine launches track the window (ScummVM has no diagnostics).
        let window = diagnostics.map { $0.hasSeenWindow ? ", after its window appeared" : ", before any window appeared" } ?? ""
        // The later Her Interactive games exit with whatever code MFC has
        // lying around, so for them a non-zero exit is judged by their own log.
        let cleanExitLog = gameStarted && signal == nil && (exitCode ?? 0) != 0
            ? HerEngineLog.cleanExitLog(inDocuments: documentsDirectory, since: launchedAt)
            : nil
        if !gameStarted {
            let how = signal.map { "was killed by \(SubprocessWatch.signalName($0))" } ?? "exited \(exitCode.map(String.init) ?? "?")"
            logger.error("■ The game never started: Wine's launcher \(how) after \(ran)")
        } else if let signal {
            logger.error("■ Game was killed by \(SubprocessWatch.signalName(signal)) after \(ran)\(window)")
        } else if let exitCode, let cleanExitLog {
            let logName = cleanExitLog.lastPathComponent
            logger.notice("■ Game exited \(exitCode) after \(ran), a clean quit: its \(logName) reports a good exit, and this engine's exit code means nothing")
        } else if let exitCode, exitCode != 0 {
            logger.error("■ Game exited \(exitCode) after \(ran)\(window) — a crash or an error on the way out")
        } else if exitCode != nil {
            logger.notice("■ Game exited 0 after \(ran)")
        } else {
            logger.notice("■ Game ended after \(ran) (exit status unknown)")
        }
        if let unexpectedQuit {
            logger.error("\(GameQuitCheck.failureMarker): nothing asked the game to quit, and \(unexpectedQuit.summary). \(unexpectedQuit.explanation)")
            for line in unexpectedQuit.wineErrors.suffix(10) {
                logger.error("    Wine: \(line)")
            }
        }

        let endedBadly = !gameStarted || signal != nil || ((exitCode ?? 0) != 0 && cleanExitLog == nil)
            || diagnostics?.hasSeenWindow == false || unexpectedQuit != nil
        if endedBadly {
            var files: [(String, String)] = []
            if let bundle = diagnostics?.lastBundle {
                files.append(("Diagnostics", bundle.path))
            }
            let summary = FailureSummary.log(logger, what: "Running \(config.gameTitle)", files: files)
            let kind = failureKind(exitCode: exitCode, signal: signal)
            recordLaunch(outcome: kind)
            report(FailureReport(
                what: "Running the game", kind: kind,
                game: config.gameSlug, engine: config.gameEngine.rawValue,
                tags: failureTags(exitCode: exitCode, signal: signal), summary: summary,
                diagnostics: diagnostics.map { diagnostics in { @Sendable in await diagnostics.bundleWhenComplete() } }
            ))
        } else {
            recordLaunch(outcome: SuccessReport.ok)
        }

        // Close info window if it's still open
        infoWindow?.close()

        logger.notice("[Game Launcher] Game has terminated, returning control to app lifecycle manager")
        return endedBadly
    }

    /// The person gave up on a launch that seemed stuck (the info window's
    /// possible-failure note) and is quitting: report it as the failure it
    /// probably is, since the game never exits to be reported on its own.
    /// Returns the report and its sending, for the info window to show.
    func reportStuckLaunch() -> (FailureReport, Task<ReportOutcome, Never>) {
        let ran = SubprocessWatch.duration(Date().timeIntervalSince(launchedAt))
        let window = diagnostics.map { $0.hasSeenWindow ? ", after its window appeared" : ", before any window appeared" } ?? ""
        logger.error("■ Gave up waiting for the launch after \(ran)\(window): the player quit while it seemed stuck")
        let stuck = stuckReport(how: "gave-up")
        recordLaunch(outcome: stuck.kind)
        report(stuck)
        return (stuck, reportTask ?? Task { .disabled })
    }

    /// Report a launch that has looked stuck for minutes, with no one having
    /// given up on it, and carry on waiting: sent only if the setting sends
    /// reports without asking, as there is nowhere to ask. Not counted as the
    /// launch's outcome, which may yet be a game. Whether it was sent.
    func reportStuckLaunchWithoutQuitting() -> Bool {
        let ran = SubprocessWatch.duration(Date().timeIntervalSince(launchedAt))
        let stuck = stuckReport(how: "automatic")
        guard let sending = FailureReporter.sendWithoutAsking(stuck) else {
            logger.notice("[Report] The launch has seemed stuck for \(ran); the report settings ask first, so it waits for a quit to be reported")
            return false
        }
        logger.error("[Report] The launch has seemed stuck for \(ran): reporting it, and still waiting")
        shared.withLock {
            $0.failureReport = stuck
            $0.reportTask = sending
        }
        return true
    }

    /// Report the game's Wine having no display driver. `final`: the launch
    /// already started afresh once for it, and the error window shows this
    /// report; otherwise it is sent as the launch starts afresh, without
    /// asking, as there is nowhere to ask. Not counted as the launch's
    /// outcome until it is final.
    func reportNoDisplay(final: Bool) {
        var files: [(String, String)] = []
        if let bundle = startupDiagnostics?.lastBundle {
            files.append(("Diagnostics", bundle.path))
        }
        let summary = FailureSummary.log(logger, what: "Starting \(config.gameTitle)", files: files)
        var tags = failureTags(exitCode: nil, signal: nil)
        tags["no_display"] = final ? "after-retry" : "retrying"
        let noDisplay = FailureReport(
            what: "Starting the game", kind: "no-display", game: config.gameSlug, engine: config.gameEngine.rawValue,
            tags: tags, summary: summary,
            diagnostics: startupDiagnostics.map { diagnostics in { @Sendable in await diagnostics.bundleWhenComplete() } }
        )
        if final {
            recordLaunch(outcome: noDisplay.kind)
            report(noDisplay)
        } else if let sending = FailureReporter.sendWithoutAsking(noDisplay) {
            shared.withLock {
                $0.failureReport = noDisplay
                $0.reportTask = sending
            }
        }
    }

    /// The report of a launch that seems stuck. `how`: given up on by the
    /// player, or sent by itself after a while.
    private func stuckReport(how: String) -> FailureReport {
        // From `startupDiagnostics`, not `diagnostics`: a launch stuck before
        // the game started (Wine's desktop, say) has a `stalled` bundle too.
        var files: [(String, String)] = []
        if let bundle = startupDiagnostics?.lastBundle {
            files.append(("Diagnostics", bundle.path))
        }
        let summary = FailureSummary.log(logger, what: "Starting \(config.gameTitle)", files: files)
        var tags = failureTags(exitCode: nil, signal: nil)
        tags["stuck_report"] = how
        return FailureReport(
            what: "Starting the game", kind: "stuck", game: config.gameSlug, engine: config.gameEngine.rawValue,
            tags: tags, summary: summary,
            diagnostics: startupDiagnostics.map { diagnostics in { @Sendable in await diagnostics.bundleWhenComplete() } }
        )
    }

    /// Count this launch for the success reports, once: a launch given up
    /// on as stuck still ends, and that end is not a second launch.
    private func recordLaunch(outcome: String) {
        let first = shared.withLock { shared in
            defer { shared.launchCounted = true }
            return !shared.launchCounted
        }
        guard first else { return }
        SuccessReporter.record(SuccessReport(
            event: .launch, outcome: outcome, game: config.gameSlug,
            source: config.gameSource, engine: config.gameEngine.rawValue
        ))
    }

    /// How a run that ended badly ended, as a report's kind: the first of
    /// the checks above that it failed.
    private func failureKind(exitCode: Int32?, signal: Int32?) -> String {
        if unexpectedQuit != nil { return "quit-unexpectedly" }
        if !gameStarted { return "never-started" }
        if signal != nil { return "killed-by-signal" }
        if let exitCode, exitCode != 0 { return "exit-code" }
        return "no-window"
    }

    private func failureTags(exitCode: Int32?, signal: Int32?) -> [String: String] {
        var tags: [String: String] = [:]
        if let exitCode { tags["exit_code"] = String(exitCode) }
        if let signal { tags["signal"] = SubprocessWatch.signalName(signal) }
        if let reason = startupDiagnostics?.lastReason { tags["diagnostics"] = reason.rawValue }
        if let copyProtection { tags["copy_protection"] = copyProtection.rawValue }
        return tags
    }

    /// Report at the detail the setting asks for, without holding up the
    /// caller: the error window shows the outcome when it comes.
    private func report(_ report: FailureReport) {
        let sending = Task.detached { await FailureReporter.report(report) }
        shared.withLock {
            $0.failureReport = report
            $0.reportTask = sending
        }
    }

    // MARK: - Game Launching

    /// Launch the game and wait for it to end. Wine, and Steam for a game
    /// that needs it, get going first; `beforeTheGame` then holds the game
    /// itself back, until the player has read the save warning, so that what
    /// can start behind it does. On the main actor, as the loading window
    /// is: every wait here is an `await`, and what blocks runs elsewhere.
    func launchGame(infoWindow: InfoWindowController? = nil, debugMode: Bool = false,
                    beforeTheGame: () async -> Void = {}) async -> LaunchOutcome {
        launchedAt = Date()
        gameStarted = false
        LogContext.enterStage("Starting the game")
        if config.gameEngine.runsInWine,
           let gameExePath = getGameLaunchInfo(config).gameExePath {
            let gameExe = URL(fileURLWithPath: gameExePath)
            let graphics = GameGraphicsAPI(exeAt: gameExe)
            logger.notice("[Helpers] \(gameExe.lastPathComponent) draws with \(graphics.logDescription)\(graphics.mayUseCncDdraw ? "" : ", so cursor lock isn't needed")")
            helperReport = InProcessHelperReport(
                armingVariables: Wine.inProcessHelperVariables(gameExe: gameExe), logger: logger)
            quitCheck = GameQuitCheck(graphicsAPI: graphics, throughSteam: config.gameEngine.needsSteam)
            copyProtection = CopyProtection(exeAt: gameExe)
            if let copyProtection {
                logger.warning("[Game Launch] \(gameExe.lastPathComponent) is wrapped in \(copyProtection.name) copy protection, which may not run under Wine")
            }
        } else if config.gameEngine == .scummvm, !scummvmPuppetVariables.isEmpty {
            helperReport = InProcessHelperReport(armingVariables: scummvmPuppetVariables, logger: logger)
        }
        if config.gameEngine.needsSteam {
            LogContext.enterStage("Starting Steam")
            do {
                let helperReport = helperReport
                let quitCheck = quitCheck
                let activity = infoWindow?.activity
                let status = steamStatusHandler(infoWindow)
                let noDisplay = NoDisplaySignal(onFirst: onNoDisplay)
                guard let lock = try await takeSteam() else {
                    logger.notice("[Steam] Not starting: another game has Steam, and the player chose to leave it")
                    return .notStarted
                }
                infoWindow?.onSignInToSteamAfresh = { [weak self] in self?.steam?.signInAfresh() }
                let config = config
                // Both block while Steam starts and signs in, so off the main thread.
                let started = try await Blocking.run {
                    try WrappSteam(lock: lock, config: config, status: status,
                                   onOutputLine: {
                                       helperReport?.observe(line: $0)
                                       quitCheck?.observe(line: $0)
                                       noDisplay.check($0)
                                       activity?.noteOutput()
                                   })
                }
                steam = started  // from here a quit can stop it
                try await Blocking.run { try started.waitUntilSignedIn(status: status) }
            } catch WrappSteam.Failure.cancelled {
                logger.notice("[Steam] Quit while waiting for Steam to sign in")
                return .notStarted
            } catch {
                reportSteamFailure(error)
                return .failedAndTold
            }
        } else if config.gameEngine.runsInWine {
            await prepareDesktop(config.wine)
        }
        await beforeTheGame()
        if isQuitting {
            logger.notice("[Game Launch] Quit before the game started")
            return .notStarted
        }
        LogContext.enterStage("Starting the game")
        // The game's own start is timed from here, not from Steam's or the
        // time the player took over the warning.
        launchedAt = Date()
        // Launch the game process (engine-specific)
        let launchResult: (process: Process?, gamePid: Int32, gameExeName: String?)
        // Steam starts the game itself, so there's no launcher process of
        // ours to watch: the game is found, and watched, by its exe.
        let launchedBySteam = config.gameEngine.launchedBySteam

        switch config.gameEngine {
        case .wine, .wineSteamSilent:
            launchResult = launchWineProcess(activity: infoWindow?.activity)
        case .wineSteam:
            launchResult = await launchViaSteam()
        case .scummvm:
            launchResult = launchScummVMProcess(activity: infoWindow?.activity)
        }

        guard launchResult.gamePid > 0 || (launchedBySteam && launchResult.gameExeName != nil) else {
            logger.critical("Failed to launch the game")
            handleGameTermination(exitCode: nil, signal: nil, infoWindow: nil)
            return .ended(exitCode: -1, failed: true, windowAppeared: false)
        }

        var gamePid = launchResult.gamePid

        // Wait for game to start
        if let gameExeName = launchResult.gameExeName {
            logger.notice("[Game Launch] Waiting for game executable to start...")
            let whileWaiting = launchedBySteam ? steamLaunchWatcher(infoWindow) : nil
            let abandonIf = launchedBySteam ? Self.steamGone() : nil
            if let detectedPid = await gameMonitor.waitForGameToStart(gameExeName: gameExeName, gamePid: gamePid, launcher: launchResult.process,
                                                                       abandonIf: abandonIf, whileWaiting: whileWaiting) {
                logger.notice("[Game Launch] Game executable detected with PID \(detectedPid)")
                gameStarted = true
                if launchedBySteam { gamePid = detectedPid }
                diagnostics?.gameStarted(pid: detectedPid)

                // Activate game window (Wine games only)
                if config.gameEngine.runsInWine {
                    logger.notice("[Game Launch] Activating game window...")
                    if await gameMonitor.activateGameWindow(gamePid: detectedPid, infoWindow: infoWindow) {
                        windowAppeared = true
                        gameWindowPid.withLock { $0 = detectedPid }
                        diagnostics?.gameWindowAppeared()
                        quitCheck?.windowDidAppear()
                        helperReport?.gameWindowAppeared()
                    }
                }
            } else if launchedBySteam {
                logger.error("[Game Launch] Steam never started \(gameExeName)")
                diagnostics?.gameExited(exitCode: -1)
                handleGameTermination(exitCode: nil, signal: nil, infoWindow: nil)
                return .ended(exitCode: -1, failed: true, windowAppeared: false)
            } else {
                logger.error("[Game Launch] \(gameExeName) was never seen running; waiting for Wine's launcher to finish")
            }
        } else {
            gameStarted = true
            // ScummVM is the game's own process, so there's nothing to find:
            // wait for its window, as for a Wine game's.
            _ = await gameMonitor.waitForGameToStart(gameExeName: "scummvm", gamePid: gamePid)
            logger.notice("[Game Launch] Waiting for ScummVM's window...")
            if await gameMonitor.activateGameWindow(gamePid: gamePid, infoWindow: infoWindow) {
                windowAppeared = true
                let pid = gamePid
                gameWindowPid.withLock { $0 = pid }
                helperReport?.gameWindowAppeared()
                gameMonitor.hideWrapperFromDock()
            }
        }

        // The loading window goes once the game's own window is up. Without
        // one, it stays, and is replaced by an error if the game then fails:
        // a game that dies before its window must not leave the player with
        // nothing on screen.
        if windowAppeared {
            infoWindow?.notifyGameLoaded()
        }
        if gameStarted {
            LogContext.enterStage("Playing")
        }

        // A logout or shutdown quits the game before the wrapp hears of it.
        let quitCheck = quitCheck
        let powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil
        ) { _ in quitCheck?.quitRequested("the Mac is logging out or shutting down") }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver) }

        // Wait for game to stop
        logger.notice("[Game Launch] Waiting for game to stop...")
        await gameMonitor.waitForGameToStop(gamePid: gamePid, process: launchResult.process)
        gameWindowPid.withLock { $0 = nil }
        // Judged straight away: how soon after a Wine error it came matters.
        // A wrapp that is quitting stopped the game itself, and a game killed
        // by a signal is already reported as one.
        if !cleanupQueue.sync(execute: { cleanupCompleted }), gameMonitor.exitSignal == nil {
            unexpectedQuit = quitCheck?.failure()
        }

        // Get exit code from GameMonitor which captured it safely
        let exitCode = gameMonitor.exitCode ?? 0
        diagnostics?.gameExited(exitCode: exitCode)

        // Judged and reported now; Steam and the desktop are finished after
        // (`finishSession`), so an error isn't held back while Steam shuts down.
        let failed = handleGameTermination(exitCode: gameMonitor.exitCode, signal: gameMonitor.exitSignal,
                                           infoWindow: windowAppeared ? infoWindow : nil)

        return .ended(exitCode: exitCode, failed: failed, windowAppeared: windowAppeared)
    }

    /// Once the game has ended: let Steam save its sign-in and stop, and
    /// release the desktop, so the Wine session can end. After whatever is
    /// to be shown has been: Steam can take a minute and a half.
    func finishSession() async {
        if let steam = claimSteam() {
            await Blocking.run { steam.finish(timeout: 90) }
        }
        releaseDesktop()
    }

    /// Steam, for whichever of the game's end and a quit gets to it first to
    /// finish: never both. Any thread: the quit's cleanup claims it from its
    /// background queue.
    private nonisolated func claimSteam() -> WrappSteam? {
        shared.withLock { shared in
            defer { shared.steam = nil }
            return shared.steam
        }
    }

    // MARK: - Wine Game Launching

    /// `activity` hears of each line Wine prints.
    private func launchWineProcess(activity: LaunchActivityMonitor?) -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        // Get game launch info
        let launchInfo = getGameLaunchInfo(config)

        logger.notice("Launching game: \(launchInfo.executable) with arguments: \(launchInfo.arguments.joined(separator: " "))")
        if let gameExeName = launchInfo.gameExeName {
            logger.notice("Game executable name: \(gameExeName)")
        }

        let wine = config.wine

        // Export commands for running Wine by hand against this prefix, as one
        // entry at debug: needed when reproducing, noise otherwise.
        logger.debug("Wine environment, for running Wine by hand:\n\(wine.shellExports)")

        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        logger.debug("Full command: \(fullCommand)")

        // Launch the game
        logger.notice("[Wine] Launching game process...")

        guard let command = launchInfo.wineCommand, let gameExeUnixPath = launchInfo.gameExePath else {
            logger.critical("ERROR: no game program to run for a Wine game")
            return (nil, -1, nil)
        }

        // Wine's output is logged line by line (reaching the terminal, the
        // log window and the export). Diagnostics sees the same lines, to keep
        // recent context and spot crashes.
        guard let diagnostics = startupDiagnostics else {
            logger.critical("ERROR: no diagnostics for a Wine game")
            return (nil, -1, nil)
        }
        let helperReport = helperReport
        let quitCheck = quitCheck
        let noDisplay = NoDisplaySignal(onFirst: onNoDisplay)
        let observe: @Sendable (String) -> Void = { line in
            diagnostics.observe(line: line)
            helperReport?.observe(line: line)
            quitCheck?.observe(line: line)
            noDisplay.check(line)
            activity?.noteOutput()
        }
        let game: WineProcess
        do {
            game = try wine.start(command,
                                  environment: Wine.inProcessHelperVariables(gameExe: URL(fileURLWithPath: gameExeUnixPath)),
                                  output: .log(wineOutputLogger, onLine: observe))
        } catch {
            logger.critical("ERROR: Failed to launch game: \(error)")
            return (nil, -1, nil)
        }
        diagnostics.wineLaunched()
        self.diagnostics = diagnostics
        let process = game.process

        logger.notice("[Wine] Game process started with PID \(process.processIdentifier)")

        // Store the process reference
        self.currentProcess = process

        return (process, process.processIdentifier, launchInfo.gameExeName)
    }

    // MARK: - Steam

    /// Have Steam start the game (`-applaunch`), for DRM that insists on it.
    private func launchViaSteam() async -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        let launchInfo = getGameLaunchInfo(config)
        guard let steam, let appID = config.steamGameId.flatMap({ Int($0) }) else {
            logger.critical("ERROR: no Steam app ID for a game launched through Steam")
            return (nil, -1, nil)
        }
        do {
            try await Blocking.run { try steam.client.launch(appID: appID) }
        } catch {
            logger.critical("ERROR: Couldn't ask Steam to launch the game: \(error.localizedDescription)")
            return (nil, -1, nil)
        }
        startupDiagnostics?.wineLaunched()
        diagnostics = startupDiagnostics
        return (nil, 0, launchInfo.gameExeName)
    }

    /// While Steam starts the game there is no launcher of ours to watch,
    /// so the wait for the game ends when Steam has gone: `steam.exe` missing
    /// from three checks in a row (a second and a half), since it restarts
    /// itself after an update.
    private static func steamGone() -> (Set<ProcessList.Entry>) -> String? {
        var missing = 0
        return { processes in
            let running = processes.contains { $0.name.lowercased() == "steam.exe" }
            missing = running ? 0 : missing + 1
            return missing >= 3 ? "Steam has exited without starting the game" : nil
        }
    }

    /// The one-Steam-at-a-time lock, once Steam is free. While another
    /// game holds it, the player can quit that game themselves and try
    /// again, have it quit for them, or leave it be — nil, which is their
    /// choice and no failure.
    private func takeSteam() async throws -> SteamActiveLock? {
        let title = config.gameTitle
        let bundleID = config.bundleId
        let taking = try await SteamActiveLock.take(bundleID: bundleID) { holder in
            await MainActor.run {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                let quoted = SteamLockHolder.quoted(title)
                return holder.ask(blocked: String(localized: "\(quoted) can't start until it quits."))
            }
        }
        switch taking {
        case .acquired(let lock): return lock
        case .cancelled: return nil
        case .held(let holder): throw WrappSteam.Failure.inUse(holder)
        }
    }

    private func reportSteamFailure(_ error: Error) {
        let (title, detail): (String, String)
        let game = config.gameTitle
        switch error {
        case WrappSteam.Failure.inUse(let holder):
            let quotedGame = SteamLockHolder.quoted(game)
            if let name = holder.name.map(SteamLockHolder.quoted) {
                (title, detail) = (String(localized: "\(name) is using Steam"),
                                   String(localized: "Only one game can use Steam at a time. Quit \(name), then open \(quotedGame) again."))
            } else {
                (title, detail) = (String(localized: "Another game is using Steam"),
                                   String(localized: "Only one game can use Steam at a time. Quit it, then open \(quotedGame) again."))
            }
        case WrappSteam.Failure.exited:
            (title, detail) = (String(localized: "Steam closed before it signed in"),
                               String(localized: "\(game) needs Steam signed in to start. Open it again to have another go."))
        case WrappSteam.Failure.stuck:
            (title, detail) = (String(localized: "Steam got stuck signing in"), String(localized: """
                \(game) needs Steam signed in to start. \
                Check that this Mac is connected to the internet, then open it again to have another go.
                """))
        default:
            (title, detail) = (String(localized: "Couldn't start Steam"), error.localizedDescription)
        }
        logger.critical("[Steam] \(title): \(detail)")
        let summary = FailureSummary.log(logger, what: "Starting Steam for \(config.gameTitle)", files: [])
        report(FailureReport(what: "Starting Steam", error: error, game: config.gameSlug,
                             engine: config.gameEngine.rawValue, summary: summary))
        showAlert(message: title, informativeText: detail)
    }

    /// Show Steam's progress in the loading window. Once signed in, what
    /// starts the game is Steam (`wine-steam`) or the wrapp, with Steam
    /// running (`wine-steam-silent`).
    /// While Steam starts the game: say when its launch is waiting on the
    /// player — the game only starts once they answer — so the loading
    /// window says so and Steam's window comes forward. One such wait is
    /// Steam asking whether to stop the game the account is playing on
    /// another computer; any other wait that lasts, apart from the routine
    /// ones Steam passes through by itself, is taken as a question too.
    /// Reads Steam's log every couple of seconds.
    private func steamLaunchWatcher(_ infoWindow: InfoWindowController?) -> (() -> Void)? {
        guard let steam, let appID = config.steamGameId.flatMap({ Int($0) }) else { return nil }
        let title = config.gameTitle
        var lastCheck = Date.distantPast
        var seen: (prompt: String, since: Date)?
        var asking: String?
        var step: String?
        return { [logger] in
            guard Date().timeIntervalSince(lastCheck) >= 2 else { return }
            lastCheck = Date()
            if let now = steam.client.launchStep(appID: appID), now != step {
                logger.debug("[Steam] Launch step: \(now)")
                step = now
                infoWindow?.noteProgress(.steamLaunchStep)
            }
            let prompt = steam.client.launchPrompt(appID: appID)
            if let prompt, prompt != seen?.prompt {
                logger.debug("[Steam] Launch waiting on \(prompt)")
                seen = (prompt, Date())
            } else if prompt == nil {
                seen = nil
            }
            let question = seen.flatMap { seen in
                seen.prompt == SteamLogs.playingElsewherePrompt
                    || (!SteamLogs.routineLaunchPrompts.contains(seen.prompt) && Date().timeIntervalSince(seen.since) >= 3)
                    ? seen.prompt : nil
            }
            guard question != asking else { return }
            let answered = asking != nil
            asking = question
            if question == SteamLogs.playingElsewherePrompt {
                logger.error("[Steam] \(SteamLogs.playingElsewhereMarker)")
                infoWindow?.setStage(.steamPlayingElsewhere)
                Task { await SteamSignInWindow.bringForward(window: "question about the other computer") }
            } else if let question {
                logger.notice("[Steam] Steam's launch is waiting on the player (\(question)); bringing its window forward")
                infoWindow?.setStage(.steamWaitingForPlayer)
                Task { await SteamSignInWindow.bringForward(window: "question (\(question))") }
            } else if answered {
                logger.notice("[Steam] Answered: Steam is starting the game")
                infoWindow?.setStage(.steamStartingGame(title: title))
            }
        }
    }

    /// Called from the thread Steam starts on, so it only uses what the
    /// loading window lets any thread call.
    private func steamStatusHandler(_ infoWindow: InfoWindowController?) -> @Sendable (WrappSteam.Status) -> Void {
        let title = config.gameTitle
        let launchedBySteam = config.gameEngine.launchedBySteam
        return { status in
            switch status {
            case .startup(let stage): infoWindow?.setStage(LoadingStage(steam: stage))
            case .waitingForSignIn: infoWindow?.setStage(.signingInToSteam)
            case .signedIn: infoWindow?.setStage(launchedBySteam ? .steamStartingGame(title: title) : .startingGame(title: title))
            case .notice(let notice): infoWindow?.setSteamNotice(notice)
            }
        }
    }

    // MARK: - Wine Desktop

    /// Start Wine's desktop and wait until it has registered the display
    /// devices, before the game runs — while the save warning shows, when it
    /// does. There is no deadline: the loading window says meanwhile whether
    /// the wait looks stuck. See `WineDesktop`.
    private func prepareDesktop(_ wine: Wine) async {
        // Debug switch, for comparing against Wine's own on-demand start.
        guard ProcessInfo.processInfo.environment["SECOND_CHANCE_PRESTART_DESKTOP"] != "0" else {
            logger.notice("[Desktop] Not pre-starting the desktop (SECOND_CHANCE_PRESTART_DESKTOP=0)")
            return
        }
        LogContext.enterStage("Starting Wine")
        let logger = logger, outputLogger = wineOutputLogger
        desktop = await WineDesktop.start(wine, timeout: .infinity, logger: logger, outputLogger: outputLogger)
    }

    /// Let the pre-started desktop shut down once the game has exited, or it
    /// keeps the whole Wine session alive. See `WineDesktop.release`. Any
    /// thread, as `claimSteam`.
    private nonisolated func releaseDesktop() {
        let claimed = shared.withLock { shared in
            defer { shared.desktop = nil }
            return shared.desktop
        }
        guard let desktop = claimed else { return }
        logger.notice("[Desktop] Game exited")
        desktop.release()
    }

    // MARK: - ScummVM Game Launching

    /// When WrappPuppeteer started the wrapp, what loads the in-process
    /// helpers' puppet control into scummvm, so WrappPuppeteer can capture
    /// and click the game without any permission. Wine games get it through
    /// winemac.so; scummvm is an ordinary binary (ad-hoc signed, no hardened
    /// runtime), so dyld inserts the dylib. The other helpers stay unarmed in
    /// it, since their variables aren't set. Empty for every player's launch.
    /// See docs/wine-in-process-helpers.md.
    private var scummvmPuppetVariables: [String: String] {
        guard Wine.puppetDirectory() != nil else { return [:] }
        let dylib = config.appPath.appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib").path
        // dyld kills a process whose inserted dylib is missing, so a wrapp
        // built without it runs the game without puppet control instead.
        guard FileManager.default.fileExists(atPath: dylib) else {
            logger.error("[Helpers] Puppet control can't be loaded into scummvm: \(dylib) is missing")
            return [:]
        }
        return ["DYLD_INSERT_LIBRARIES": dylib, "PUPPET_CONTROL_EXE": "scummvm"]
    }

    private func launchScummVMProcess(activity: LaunchActivityMonitor?) -> (process: Process?, gamePid: Int32, gameExeName: String?) {
        // Get game launch info
        let launchInfo = getGameLaunchInfo(config)

        logger.notice("ScummVM binary: \(launchInfo.executable)")
        logger.notice("Launching ScummVM with arguments:")
        for arg in launchInfo.arguments {
            logger.notice("  \(arg)")
        }

        // Print full command with proper quoting
        let fullCommand = launchInfo.formatLaunchCommand()
        logger.notice("Full command: \(fullCommand)")

        // Execute ScummVM with output captured line-by-line through the
        // logger (terminal users still see it via stderr when isatty, and it
        // now also reaches the log window and the export).
        let task = TaggedProcess(logger: scummvmOutputLogger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        let puppetVariables = scummvmPuppetVariables
        let helperReport = helperReport
        if !puppetVariables.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(puppetVariables) { $1 }
        }
        task.onLine = { line in
            helperReport?.observe(line: line)
            activity?.noteOutput()
        }

        do {
            try task.run()
            logger.notice("[ScummVM] Game process started with PID \(task.processIdentifier)")

            // Store the process reference
            self.currentProcess = task.process

            return (task.process, task.processIdentifier, nil)  // No gameExeName for ScummVM
        } catch {
            logger.critical("ERROR: Failed to launch ScummVM: \(error.localizedDescription)")
            return (nil, -1, nil)
        }
    }
}
