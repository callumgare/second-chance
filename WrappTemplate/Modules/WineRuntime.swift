//
//  WineRuntime.swift
//  WrappTemplate
//
//  The Wine module in the wrapp: its desktop, the game started in it, what
//  watches the game, and ending its session.

import Foundation
import GameCatalog
import Logging
import SecondChanceKit
import Synchronization

/// Wine, in the wrapp: for a game it starts, or one Steam starts in it.
final class WineRuntime: GameStarting {
    nonisolated static let id = ModuleID.wine

    private let config: GameConfig
    /// The desktop `prepare` started, if it did; claimed once, by the
    /// game's end or a quit, whichever comes first (`releaseDesktop`).
    private let desktop = Mutex<WineDesktop?>(nil)
    /// Where the game's helpers' reports come from when they can't come
    /// through its output (`HelperReportFile`); stopped with the desktop.
    private let helperReports = Mutex<HelperReportFile?>(nil)
    /// Captures a diagnostics bundle if the game starts badly. Made with the
    /// module, so a launch that stalls before the game starts can be
    /// captured too.
    let diagnostics: StartupDiagnostics
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What Wine and the game print: a category of its own, so it reads
    /// apart from the launcher's lines about it.
    private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Wine")

    required init(config: GameConfig) {
        self.config = config
        diagnostics = StartupDiagnostics(gameSlug: config.gameSlug, gameTitle: config.gameTitle, wine: config.wine)
    }

    var stopsOnQuit: Bool { true }

    // Only this game's Wine counts as its launch's progress: another game's,
    // running alongside, would keep a stuck launch looking busy.
    var ownsProcess: (@Sendable (pid_t) -> Bool)? {
        let server = config.wine.server
        return { pid in !server.isElsewhere(pid) }
    }

    func connectSaves(_ saves: URL) throws(ModuleFailure) {
        let couldNot = String(localized: "Couldn't Open Your Saved Games")
        do {
            try config.wine.drives.mount(saves, as: "a")
            // A wrapp built when prefixes had a Z: showing the whole Mac
            // (WineDrives): the game never needed it.
            config.wine.drives.block("z")
        } catch {
            logger.critical("ERROR: Failed to mount directory into Wine: \(error)")
            throw ModuleFailure(
                what: "Mounting the saves folder", error: error, title: couldNot,
                detail: String(localized: "The game couldn't reach the folder where your saved games are kept: \(error.localizedDescription)"))
        }
        // Where the game keeps its saves, linked to the player's saves folder.
        do {
            try SavesLink.link(config.wine.documents, to: saves)
        } catch {
            logger.critical("ERROR: Failed to create symbolic link for Documents directory: \(error)")
            throw ModuleFailure(
                what: "Linking the saves folder", error: error, title: couldNot,
                detail: String(localized: "The game couldn't reach the folder where your saved games are kept: \(error.localizedDescription)"))
        }
    }

    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?) {
        guard let gameExe else { return }
        let (graphics, declared) = Wine.graphicsAPI(
            gameExe: gameExe, game: GameInfoProvider.shared.gameInfo(for: config.gameSlug), launch: config.launch)
        let said = declared ? ", as its launch says" : ""
        let lock = config.launch.cursorLock(inferred: graphics.mayUseCncDdraw)
        let why = config.launch.choosesItsHelpers ? "its launch doesn't ask for it" : "it doesn't draw through cnc-ddraw"
        logger.notice("[Helpers] \(gameExe.lastPathComponent) draws with \(graphics.logDescription)\(said)\(lock ? "" : ", and cursor lock isn't armed: \(why)")")
        watchers.helperReport = InProcessHelperReport(
            armingVariables: Wine.inProcessHelperVariables(gameExe: gameExe, declared: graphics, launch: config.launch), logger: logger)
        // Steam's launches are judged differently: Steam stays running.
        watchers.quitCheck = GameQuitCheck(graphicsAPI: graphics, throughSteam: config.composition.has(.steam))
        watchers.copyProtection = CopyProtection(exeAt: gameExe)
        if let copyProtection = watchers.copyProtection {
            logger.warning("[Game Launch] \(gameExe.lastPathComponent) is wrapped in \(copyProtection.name) copy protection, which may not run under Wine")
        }
    }

    /// Start Wine's desktop and wait until it has registered the display
    /// devices, before the game runs — while the save warning shows, when it
    /// does. There is no deadline: the loading window says meanwhile whether
    /// the wait looks stuck. See `WineDesktop`. Under Steam, Steam's start
    /// has started the session already. Meanwhile GStreamer's plugin cache
    /// is built if this copy has none (the build normally has), so the game
    /// doesn't build it as it first plays a sound or video (`GStreamerCache`).
    func prepare(_ launch: LaunchContext) async -> PrepareOutcome {
        let wine = config.wine, logger = logger
        async let cache: Void = wine.warmGStreamerCache(logger: logger)
        let outcome = await prepareSession(launch)
        await cache
        return outcome
    }

    private func prepareSession(_ launch: LaunchContext) async -> PrepareOutcome {
        if let path = config.wineSessionVariables[HelperReportFile.variable] {
            let file = HelperReportFile(url: URL(fileURLWithPath: path))
            let watchers = launch.watchers
            file.start { line in watchers.observe(line: line) }
            helperReports.withLock { $0 = file }
        }
        guard !config.composition.has(.steam) else { return .ready }
        // Debug switch, for comparing against Wine's own on-demand start.
        guard ProcessInfo.processInfo.environment["SECOND_CHANCE_PRESTART_DESKTOP"] != "0" else {
            logger.notice("[Desktop] Not pre-starting the desktop (SECOND_CHANCE_PRESTART_DESKTOP=0)")
            return .ready
        }
        LogContext.enterStage("Starting Wine")
        let started = await WineDesktop.start(config.wine, timeout: .infinity, logger: logger, outputLogger: outputLogger)
        desktop.withLock { $0 = started }
        return .ready
    }

    // MARK: - Starting the game

    /// What Wine runs to start the game: by name, from its own folder, as
    /// games look for their files beside them.
    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo {
        let gameExeUnixPath = WrappLayout.onDriveC(config.gameExePath, in: config.wine.driveC).path
        let gameExeName = (gameExeUnixPath as NSString).lastPathComponent
        let gameExeDir = (gameExeUnixPath as NSString).deletingLastPathComponent
        let command = WineCommand.start(gameExeName, unixPath: false, in: URL(fileURLWithPath: gameExeDir))
        return GameLaunchInfo(
            executable: command.executable(in: config.wine).path,
            arguments: command.processArguments,
            workingDirectory: gameExeDir,
            gameExeName: gameExeName,
            gameExePath: gameExeUnixPath,
            wineCommand: command
        )
    }

    var findsGame: GameDiscovery { .wineProgram }

    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = Self.launchInfo(config)

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
            return .failed
        }

        // Wine's output is logged line by line (reaching the terminal, the
        // log window and the export). Diagnostics sees the same lines, to keep
        // recent context and spot crashes.
        let watchers = launch.watchers
        let diagnostics = diagnostics
        let game: WineProcess
        do {
            game = try wine.start(command,
                                  environment: Wine.inProcessHelperVariables(gameExe: URL(fileURLWithPath: gameExeUnixPath),
                                                                             game: GameInfoProvider.shared.gameInfo(for: config.gameSlug),
                                                                             launch: config.launch),
                                  output: .log(outputLogger, onLine: { line in
                                      diagnostics.observe(line: line)
                                      watchers.observe(line: line)
                                  }))
        } catch {
            logger.critical("ERROR: Failed to launch game: \(error)")
            return .failed
        }
        diagnostics.wineLaunched()
        let process = game.process

        logger.notice("[Wine] Game process started with PID \(process.processIdentifier)")
        return LaunchResult(process: process, gamePid: process.processIdentifier, gameExeName: launchInfo.gameExeName)
    }

    // MARK: - Stopping

    func finishAfterGame() async {
        releaseDesktop()
    }

    // The desktop's start.exe keeps the session going until it is let go, so
    // the session could never end by itself in its grace period, and every
    // quit waited it out.
    nonisolated func finishForQuit(onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?) {
        releaseDesktop()
        let server = config.wine.server
        logger.debug("[Cleanup/performCleanup] Shutting down Wine...")
        let periods = GameLauncher.quitPeriods()
        Blocking.wait {
            await server.shutDown(gracePeriod: periods.grace, stopPeriod: periods.stop) { onQuitStep?(.init($0)) }
        }
        logger.debug("[Cleanup/performCleanup] Wine shut down")
    }

    /// After the game has ended by itself: wait for the rest of its Wine
    /// session (explorer, Wine's services, the server) to finish, so the
    /// wrapp never quits leaving Wine running in the prefix.
    func waitForSessionToEnd(onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?) async {
        // Generous: it ends by itself in seconds, more on a loaded Mac, and
        // only a session that is stuck reaches the kill. Not for a Big Fish
        // game: its launcher outlives it, running the game's Big Fish
        // launcher again and then opening the Game Manager, which kept the
        // session going for the whole wait. None of that is needed now.
        let server = config.wine.server
        let periods = GameLauncher.quitPeriods(grace: config.composition.launcher == .bigFish ? 0 : 30)
        await server.shutDown(gracePeriod: periods.grace, stopPeriod: periods.stop) { onQuitStep?(.init($0)) }
    }

    /// Let the pre-started desktop shut down once the game has exited, or it
    /// keeps the whole Wine session alive. See `WineDesktop.release`. Any
    /// thread: the quit's cleanup releases it from its background queue.
    private nonisolated func releaseDesktop() {
        helperReports.withLock { file in
            file?.stop()
            file = nil
        }
        let claimed = desktop.withLock { desktop in
            defer { desktop = nil }
            return desktop
        }
        guard let claimed else { return }
        logger.notice("[Desktop] Game exited")
        claimed.release()
    }

    func launchShell() {
        launchWineShell(config)
    }
}
