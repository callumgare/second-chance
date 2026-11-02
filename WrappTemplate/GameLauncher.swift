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

/// What the wrapp runs to start the game, from the module that starts it.
nonisolated func getGameLaunchInfo(_ config: GameConfig) -> GameLaunchInfo {
    // A wrapp's settings only name modules it can run (`RuntimeModules`).
    (RuntimeModules.launcher(of: config.composition) ?? WineRuntime.self).launchInfo(config)
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
    /// The modules the wrapp's composition has: what gets going, starts the
    /// game and stops (`RuntimeModule`).
    private let modules: RuntimeModules
    private var currentProcess: Process?
    private var cleanupCompleted = false
    /// Captures a diagnostics bundle if a Wine game starts badly; nil for
    /// ScummVM. Wine's, made with it, so a launch that stalls before the
    /// game starts (`captureDiagnostics`) can be captured too.
    private let startupDiagnostics: StartupDiagnostics?
    /// `startupDiagnostics`, once the game has been launched; nil before.
    private var diagnostics: StartupDiagnostics?
    /// What the launch thread, the main thread (a stuck launch's report)
    /// and the cleanup queue all reach, so behind a lock.
    private struct Shared {
        var launchCounted = false
        var failureReport: FailureReport?
        var reportTask: Task<ReportOutcome, Never>?
    }
    private let shared = Mutex(Shared())
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
    /// What watches the game while it runs, armed by its modules: the
    /// in-process helpers' report, Wine's quit check (nil for ScummVM), and
    /// copy protection.
    private var watchers: LaunchWatchers?
    /// What the in-process helpers report from inside the game.
    private var helperReport: InProcessHelperReport? { watchers?.helperReport }
    /// Judges whether a Wine game's exit was a quit; nil for ScummVM.
    private var quitCheck: GameQuitCheck? { watchers?.quitCheck }
    /// Set when the game's exit was no quit, but the game failing: it quit
    /// before it had started, or just after Wine reported an error.
    private(set) var unexpectedQuit: GameQuitCheck.Failure?
    /// The copy protection the game's .exe is wrapped in; Wine games only.
    var copyProtection: CopyProtection? { watchers?.copyProtection }
    /// The failure report for a run that ended badly, and its sending — for
    /// the error window to show, and for the wrapp to wait on before it exits.
    nonisolated var failureReport: FailureReport? { shared.withLock { $0.failureReport } }
    nonisolated var reportTask: Task<ReportOutcome, Never>? { shared.withLock { $0.reportTask } }
    private let cleanupQueue = DispatchQueue(label: "com.gamewrapper.cleanup")
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")

    init(config: GameConfig, gameMonitor: GameMonitor, modules: RuntimeModules) {
        self.config = config
        self.gameMonitor = gameMonitor
        self.modules = modules
        startupDiagnostics = modules.module(WineRuntime.self)?.diagnostics
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

        // Each module with something to stop (Wine's server, Steam), last
        // started first, on a background queue: .userInitiated, as on a Mac
        // with every core busy .utility work waits for seconds at a time,
        // and the quit with it.
        let stopping = modules.all.reversed().filter(\.stopsOnQuit)
        guard !stopping.isEmpty else {
            logger.debug("[Cleanup/performCleanup] Nothing to stop, cleanup is immediate")
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [logger] in
            for module in stopping {
                module.finishForQuit(onQuitStep: onQuitStep)
            }
            logger.debug("[Cleanup/performCleanup] About to call completion handler")
            completion()
        }
    }

    /// The wrapp is quitting (⌘Q, a signal): `performCleanup` has stopped the
    /// game, waits for Wine, and ends the wrapp once it's done.
    var isQuitting: Bool { cleanupQueue.sync { cleanupCompleted } }

    /// After the game has ended by itself: wait for the rest of its Wine
    /// session to finish, so the wrapp never quits leaving Wine running in
    /// the prefix. Nothing to wait for with ScummVM.
    func waitForSessionToEnd() async {
        await modules.module(WineRuntime.self)?.waitForSessionToEnd(onQuitStep: onQuitStep)
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
                game: config.gameSlug, engine: config.composition.engineTag,
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
            what: "Starting the game", kind: "no-display", game: config.gameSlug, engine: config.composition.engineTag,
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
            what: "Starting the game", kind: "stuck", game: config.gameSlug, engine: config.composition.engineTag,
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
            source: config.gameSource, engine: config.composition.engineTag
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
        let watchers = LaunchWatchers(onNoDisplay: onNoDisplay, activity: infoWindow?.activity)
        self.watchers = watchers
        let gameExe = getGameLaunchInfo(config).gameExePath.map(URL.init(fileURLWithPath:))
        for module in modules.all {
            module.armWatchers(watchers, gameExe: gameExe)
        }
        let launch = LaunchContext(config: config, infoWindow: infoWindow, watchers: watchers, modules: modules,
                                   report: { [weak self] in self?.report($0) })
        // Each gets going behind the save warning, in start order.
        for module in modules.all {
            switch await module.prepare(launch) {
            case .ready: continue
            case .notStarted: return .notStarted
            case .failedAndTold: return .failedAndTold
            }
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
        let launcher = modules.launcher
        let launchResult = await launcher.startGame(launch)
        currentProcess = launchResult.process
        // Steam starts the game itself, and so does Big Fish's DRM service,
        // so there's no launcher process of ours to watch: the game is
        // found, and watched, by its exe.
        let startedElsewhere = launcher.findsGame == .wineProgramStartedElsewhere
        if launchResult.gamePid >= 0, launcher.findsGame != .ownProcess {
            diagnostics = startupDiagnostics
        }

        guard launchResult.gamePid > 0 || (startedElsewhere && launchResult.gameExeName != nil) else {
            logger.critical("Failed to launch the game")
            handleGameTermination(exitCode: nil, signal: nil, infoWindow: nil)
            return .ended(exitCode: -1, failed: true, windowAppeared: false)
        }

        var gamePid = launchResult.gamePid

        // Wait for game to start
        if let gameExeName = launchResult.gameExeName {
            logger.notice("[Game Launch] Waiting for game executable to start...")
            let whileWaiting = launcher.whileWaitingForGame(launch)
            let abandonIf = launcher.abandonWaitingIf()
            if let detectedPid = await gameMonitor.waitForGameToStart(gameExeName: gameExeName, gamePid: gamePid, launcher: launchResult.process,
                                                                       abandonIf: abandonIf, whileWaiting: whileWaiting) {
                logger.notice("[Game Launch] Game executable detected with PID \(detectedPid)")
                gameStarted = true
                if startedElsewhere { gamePid = detectedPid }
                diagnostics?.gameStarted(pid: detectedPid)

                // Activate the game's window: a Wine program's own.
                if launcher.findsGame != .ownProcess {
                    logger.notice("[Game Launch] Activating game window...")
                    let shownBy = launcher.windowMayBeAnotherProcess
                        ? await gameMonitor.activateGameWindow(gamePid: detectedPid, infoWindow: infoWindow, anyRunning: gameExeName)
                        : await gameMonitor.activateGameWindow(gamePid: detectedPid, infoWindow: infoWindow) ? detectedPid : nil
                    if let shownBy {
                        windowAppeared = true
                        gameWindowPid.withLock { $0 = shownBy }
                        diagnostics?.gameWindowAppeared()
                        quitCheck?.windowDidAppear()
                        helperReport?.gameWindowAppeared()
                    }
                }
            } else if startedElsewhere {
                logger.error("[Game Launch] \(type(of: launcher).id) never started \(gameExeName)")
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
        for module in modules.all.reversed() {
            await module.finishAfterGame()
        }
    }
}
