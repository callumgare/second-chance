//
//  BigFishRuntime.swift
//  WrappTemplate
//
//  The Big Fish module in the wrapp: a game Big Fish sold, started the way
//  Big Fish's own Play does, through its DRM service, in the wrapp's Wine.

import Foundation
import GameCatalog
import Logging
import SecondChanceKit

/// Big Fish's programs, starting a game they sold in the wrapp's Wine: the
/// launcher for a wrapp built from a Big Fish Games purchase
/// (docs/big-fish.md).
final class BigFishRuntime: GameStarting {
    nonisolated static let id = ModuleID.bigFish

    /// What Big Fish's Game Manager opens a game's `.bfg` files with.
    nonisolated static let processExe = #"C:\Program Files (x86)\bfgclient\bfgprocess.exe"#

    private let config: GameConfig
    /// A trial started through the Game Manager, for starting it again
    /// (`whileWaitingForGame`).
    private var trial: TrialRestart?
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Wine")

    required init(config: GameConfig) {
        self.config = config
    }

    // Big Fish's copy protection makes the game slow to start.
    func firstStage(gameTitle: String) -> LoadingStage? { .bigFishStartingGame(title: gameTitle) }

    // MARK: - Starting the game

    /// As Big Fish's own Play shortcut does: bfgprocess hands the game's
    /// `.bfg` to Big Fish's DRM service, which runs its launcher, which runs
    /// the game. The game is still found, and watched, by its exe.
    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo {
        let game = WineRuntime.launchInfo(config)
        guard let launchFile = config.bigFishLaunchFile else { return game }
        let command = WineCommand.program(processExe, ["C:" + launchFile.replacingOccurrences(of: "/", with: "\\")])
        return GameLaunchInfo(
            executable: command.executable(in: config.wine).path,
            arguments: command.processArguments,
            workingDirectory: game.workingDirectory,
            gameExeName: game.gameExeName,
            gameExePath: game.gameExePath,
            wineCommand: command
        )
    }

    /// What every Wine program of an owned game's session runs with
    /// (`GameConfig.wineSessionVariables`): the game's in-process helpers,
    /// and the Game Manager's windows hidden, as Big Fish's launcher opens it
    /// as the game ends (never seen, as its file to show it is never made).
    /// Not just what `bfgprocess` is given: it hands the game to Big Fish's
    /// DRM service, which starts it with the environment `services.exe`
    /// passes on, the one the session's first program started with, and
    /// with no output of the wrapp's for its helpers' reports.
    /// Nothing for a trial, which `startTrial` starts with them itself, or a
    /// game that isn't Big Fish's.
    nonisolated static func sessionVariables(_ config: GameConfig) -> [String: String] {
        guard config.bigFishLaunchFile != nil, !config.bigFishTrial,
              let gameExe = WineRuntime.launchInfo(config).gameExePath else { return [:] }
        // The catalog says what the game draws with: Armadillo hides its .exe's imports.
        var variables = Wine.inProcessHelperVariables(gameExe: URL(fileURLWithPath: gameExe),
                                                      game: GameInfoProvider.shared.gameInfo(for: config.gameSlug),
                                                      launch: config.launch)
        let neverShown = FileManager.default.temporaryDirectory.appendingPathComponent("second-chance-never-shown")
        variables.merge(Wine.hiddenWindowsVariables(exe: "bfgclient.exe", showFile: neverShown)) { game, _ in game }
        // The service starts the game with no output of the wrapp's, so its
        // helpers' reports come through a file (`WineRuntime.prepare`).
        variables[HelperReportFile.variable] = HelperReportFile.url().path
        return variables
    }

    var findsGame: GameDiscovery { .wineProgramStartedElsewhere }

    // Big Fish's games run under Armadillo as two processes of the same exe;
    // the window is the second's.
    var windowMayBeAnotherProcess: Bool { true }

    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        if config.bigFishTrial { return await startTrial(launch) }
        let launchInfo = Self.launchInfo(config)
        guard let command = launchInfo.wineCommand, launchInfo.gameExePath != nil else {
            logger.critical("ERROR: no game program to run for a Big Fish game")
            return .failed
        }
        logger.notice("Launching game through Big Fish: \(launchInfo.executable) with arguments: \(launchInfo.arguments.joined(separator: " "))")
        let watchers = launch.watchers
        let diagnostics = launch.modules.module(WineRuntime.self)?.diagnostics
        // The helpers' variables are the session's (`sessionVariables`).
        do {
            _ = try config.wine.start(command,
                                      output: .log(outputLogger, onLine: { line in
                                          diagnostics?.observe(line: line)
                                          watchers.observe(line: line)
                                      }))
        } catch {
            logger.critical("ERROR: Failed to launch game: \(error)")
            return .failed
        }
        diagnostics?.wineLaunched()
        // bfgprocess hands the launch on and exits within seconds.
        return LaunchResult(process: nil, gamePid: 0, gameExeName: launchInfo.gameExeName)
    }

    /// Start a Big Fish free trial: through the Game Manager's Play Now, as
    /// launching its `.bfg` file only opens the Game Manager for a trial. Only
    /// the integration tests build trials (docs/big-fish.md).
    private func startTrial(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = WineRuntime.launchInfo(config)
        guard let sku = config.bigFishSKU.flatMap(BigFishSKU.init) else {
            logger.critical("ERROR: no Big Fish SKU for a Big Fish trial")
            return .failed
        }
        // The game is the Game Manager's child, so it has the Game Manager's
        // environment and output: the helpers are armed through them.
        let watchers = launch.watchers
        let diagnostics = launch.modules.module(WineRuntime.self)?.diagnostics
        let manager = BigFishGameManager(wrappPath: config.appPath, prefixDir: config.winePrefix,
                                         gameExe: launchInfo.gameExePath.map(URL.init(fileURLWithPath:)),
                                         game: GameInfoProvider.shared.gameInfo(for: config.gameSlug),
                                         launch: config.launch, engineHas: config.wineEngineHas,
                                         onOutputLine: { line in
                                             diagnostics?.observe(line: line)
                                             watchers.observe(line: line)
                                         })
        do {
            try await manager.start(timeout: 600)
            try await manager.play(sku)
        } catch {
            logger.critical("ERROR: Couldn't have the Game Manager start the trial: \(error)")
            return .failed
        }
        diagnostics?.wineLaunched()
        trial = TrialRestart(manager: manager, sku: sku)
        return LaunchResult(process: nil, gamePid: 0, gameExeName: launchInfo.gameExeName)
    }

    /// How many times a trial is started again in a fresh Wine session when
    /// Big Fish's DRM ends without starting the game.
    nonisolated static let trialRestarts = 2
    /// How long neither Big Fish's launcher nor its activator may run, once
    /// one has, before the game counts as not started: between them they
    /// leave gaps of a few seconds.
    nonisolated static let trialDRMGoneFor: TimeInterval = 20

    /// A trial whose DRM may need starting again, and where that has got to.
    private final class TrialRestart {
        let manager: BigFishGameManager
        let sku: BigFishSKU
        var restarts = 0
        /// Ending the session and starting the Game Manager again.
        var restarting = false
        /// Why the game won't start, once it has been started again as often
        /// as it may be.
        var gaveUp: String?

        init(manager: BigFishGameManager, sku: BigFishSKU) {
            self.manager = manager
            self.sku = sku
        }
    }

    /// For a trial: when Big Fish's DRM (its activator and the game's
    /// launcher) has run and ended without starting the game, end the Wine
    /// session and press Play Now again in a fresh one. Wine 10's WMI
    /// deadlocks in the DRM on about one trial launch in five
    /// (docs/wine.md#wmi-deadlock), and the Game Manager then waits for ever;
    /// pressing Play Now again in the same session didn't help (2026-11-13),
    /// a fresh session usually starts it.
    func whileWaitingForGame(_ launch: LaunchContext) -> (() -> Void)? {
        guard let trial else { return nil }
        var watched = ["gmactivator.exe"]
        if let launcher = trial.manager.installedGame(trial.sku)?.launcher { watched.append(launcher.lowercased()) }
        var drmRan = false
        var goneSince: Date?
        var lastCheck = Date.distantPast
        return { [logger] in
            guard !trial.restarting, trial.gaveUp == nil, Date().timeIntervalSince(lastCheck) >= 2,
                  let processes = ProcessList.recent(maxAge: .seconds(2)) else { return }
            lastCheck = Date()
            if processes.wine.contains(where: { watched.contains($0.name.lowercased()) }) {
                drmRan = true
                goneSince = nil
                return
            }
            guard drmRan else { return }
            let since = goneSince ?? Date()
            goneSince = since
            guard Date().timeIntervalSince(since) >= Self.trialDRMGoneFor else { return }
            drmRan = false
            goneSince = nil
            guard trial.restarts < Self.trialRestarts else {
                trial.gaveUp = "Big Fish's DRM ended without starting the game, \(Self.trialRestarts + 1) times"
                return
            }
            trial.restarts += 1
            trial.restarting = true
            logger.warning("""
                [Game Launch] Big Fish's DRM ended without starting the game; \
                starting the trial again in a fresh Wine session (\(trial.restarts) of \(Self.trialRestarts))
                """)
            Task {
                defer { trial.restarting = false }
                await trial.manager.shutdown(timeout: 30)
                do {
                    try await trial.manager.start(timeout: 600)
                    try await trial.manager.play(trial.sku)
                } catch {
                    logger.error("[Game Launch] Couldn't start the trial again: \(error)")
                    trial.gaveUp = "the Game Manager couldn't start the trial again: \(error)"
                }
            }
        }
    }

    /// While Big Fish's DRM service starts the game there's nothing of ours to
    /// watch: the wait ends when bfgprocess and the service have both gone,
    /// three checks in a row, without the game appearing. For a trial, not
    /// while it's being started again, and once it won't be again, when its
    /// DRM has ended without starting the game.
    func abandonWaitingIf() -> ((Set<ProcessList.Entry>) -> String?)? {
        let trial = trial
        var missing = 0
        return { processes in
            if let trial {
                if let gaveUp = trial.gaveUp { return gaveUp }
                if trial.restarting {
                    missing = 0
                    return nil
                }
            }
            let running = processes.contains { ["bfgprocess.exe", "bfggameservices.exe"].contains($0.name.lowercased()) }
            missing = running ? 0 : missing + 1
            return missing >= 3 ? "Big Fish's launcher has exited without starting the game" : nil
        }
    }

    func launchShell() {
        launchWineShell(config)
    }
}
