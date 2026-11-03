//
//  SteamRuntime.swift
//  WrappTemplate
//
//  The Steam module in the wrapp: Steam started and signed in before the
//  game, the game started through it when its DRM insists, and Steam
//  stopped afterwards. WrappSteam is Steam itself.

import AppKit
import Foundation
import Logging
import SecondChanceKit
import SecondChanceReporting
import Synchronization

/// Steam, running in the wrapp's Wine: a service for a game that needs it
/// running, and the launcher for one whose DRM wants Steam to start it.
final class SteamRuntime: GameStarting {
    nonisolated static let id = ModuleID.steam

    private let config: GameConfig
    /// Steam, once started; claimed once, by the game's end or a quit,
    /// whichever comes first: never both.
    private let steam = Mutex<WrappSteam?>(nil)
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")

    required init(config: GameConfig) {
        self.config = config
    }

    /// Whether Steam starts the game, rather than only running beside it.
    private var startsTheGame: Bool { config.composition.launcher == Self.id }

    var stopsOnQuit: Bool { true }

    func firstStage(gameTitle: String) -> LoadingStage? { .startingSteam }

    /// Steam's logs folder, whose activity is a sign of the launch's progress.
    var logsDir: URL {
        config.winePrefix.appendingPathComponent(SteamClient.steamDirInPrefix).appendingPathComponent("logs")
    }

    // MARK: - Starting Steam

    func prepare(_ launch: LaunchContext) async -> PrepareOutcome {
        LogContext.enterStage("Starting Steam")
        let infoWindow = launch.infoWindow
        do {
            let watchers = launch.watchers
            let status = statusHandler(infoWindow)
            guard let lock = try await takeSteam() else {
                logger.notice("[Steam] Not starting: another game has Steam, and the player chose to leave it")
                return .notStarted
            }
            infoWindow?.onSignInToSteamAfresh = { [weak self] in self?.steam.withLock { $0 }?.signInAfresh() }
            let config = config
            // Both block while Steam starts and signs in, so off the main thread.
            let started = try await Blocking.run {
                try WrappSteam(lock: lock, config: config, status: status,
                               onOutputLine: { watchers.observe(line: $0) })
            }
            steam.withLock { $0 = started }  // from here a quit can stop it
            try await Blocking.run { try started.waitUntilSignedIn(status: status) }
            return .ready
        } catch WrappSteam.Failure.cancelled {
            logger.notice("[Steam] Quit while waiting for Steam to sign in")
            return .notStarted
        } catch {
            reportFailure(error, launch)
            return .failedAndTold
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

    private func reportFailure(_ error: Error, _ launch: LaunchContext) {
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
        launch.report(FailureReport(what: "Starting Steam", error: error, game: config.gameSlug,
                                    engine: config.composition.engineTag, summary: summary))
        showAlert(message: title, informativeText: detail)
    }

    /// Show Steam's progress in the loading window. Once signed in, what
    /// starts the game is Steam (`wine-steam`) or the wrapp, with Steam
    /// running (`wine-steam-silent`). Called from the thread Steam starts
    /// on, so it only uses what the loading window lets any thread call.
    private func statusHandler(_ infoWindow: InfoWindowController?) -> @Sendable (WrappSteam.Status) -> Void {
        let title = config.gameTitle
        let startsTheGame = startsTheGame
        return { status in
            switch status {
            case .startup(let stage): infoWindow?.setStage(LoadingStage(steam: stage))
            case .waitingForSignIn: infoWindow?.setStage(.signingInToSteam)
            case .signedIn: infoWindow?.setStage(startsTheGame ? .steamStartingGame(title: title) : .startingGame(title: title))
            case .notice(let notice): infoWindow?.setSteamNotice(notice)
            }
        }
    }

    // MARK: - Starting the game, for DRM that insists on Steam

    // Steam's games run in Wine.
    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo { WineRuntime.launchInfo(config) }

    var findsGame: GameDiscovery { .wineProgramStartedElsewhere }

    /// Have Steam start the game (`-applaunch`).
    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = Self.launchInfo(config)
        guard let steam = steam.withLock({ $0 }), let appID = config.steamGameId.flatMap({ Int($0) }) else {
            logger.critical("ERROR: no Steam app ID for a game launched through Steam")
            return .failed
        }
        do {
            try await Blocking.run { try steam.client.launch(appID: appID) }
        } catch {
            logger.critical("ERROR: Couldn't ask Steam to launch the game: \(error.localizedDescription)")
            return .failed
        }
        launch.modules.module(WineRuntime.self)?.diagnostics.wineLaunched()
        return LaunchResult(process: nil, gamePid: 0, gameExeName: launchInfo.gameExeName)
    }

    /// While Steam starts the game there is no launcher of ours to watch,
    /// so the wait for the game ends when Steam has gone: `steam.exe` missing
    /// from three checks in a row (a second and a half), since it restarts
    /// itself after an update.
    func abandonWaitingIf() -> ((Set<ProcessList.Entry>) -> String?)? {
        var missing = 0
        return { processes in
            let running = processes.contains { $0.name.lowercased() == "steam.exe" }
            missing = running ? 0 : missing + 1
            return missing >= 3 ? "Steam has exited without starting the game" : nil
        }
    }

    /// While Steam starts the game: say when its launch is waiting on the
    /// player — the game only starts once they answer — so the loading
    /// window says so and Steam's window comes forward. One such wait is
    /// Steam asking whether to stop the game the account is playing on
    /// another computer; any other wait that lasts, apart from the routine
    /// ones Steam passes through by itself, is taken as a question too.
    /// Reads Steam's log every couple of seconds.
    func whileWaitingForGame(_ launch: LaunchContext) -> (() -> Void)? {
        let infoWindow = launch.infoWindow
        guard let steam = steam.withLock({ $0 }), let appID = config.steamGameId.flatMap({ Int($0) }) else { return nil }
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

    // MARK: - Stopping

    /// Once the game has ended: let Steam save its sign-in and stop. After
    /// whatever is to be shown has been: Steam can take a minute and a half.
    func finishAfterGame() async {
        if let steam = claim() {
            await Blocking.run { steam.finish(timeout: 90) }
        }
    }

    // Steam would keep the Wine session alive, and its sign-in has to be
    // saved and taken out of the wrapp on the way out. Briefly: the quit
    // fallback kills everything after 15s, and Steam has been seen to ignore
    // -shutdown when it's stuck.
    nonisolated func finishForQuit(onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?) {
        if let steam = claim() {
            onQuitStep?(.closingSteam)
            steam.finish(timeout: 8)
        }
    }

    /// Steam, for whichever of the game's end and a quit gets to it first to
    /// finish. Any thread.
    private nonisolated func claim() -> WrappSteam? {
        steam.withLock { steam in
            defer { steam = nil }
            return steam
        }
    }

    // Steam's games run in Wine.
    func launchShell() {
        launchWineShell(config)
    }
}
