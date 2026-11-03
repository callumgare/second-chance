//
//  RuntimeModule.swift
//  WrappTemplate
//
//  What each module the wrapp runs does at launch: get going, start the
//  game, and stop.

import AppKit
import Foundation
import Logging
import SecondChanceKit
import SecondChanceReporting

/// What a module does in the wrapp, when the wrapp's composition has it.
///
/// The launcher (`GameLauncher`) makes one for each module in the
/// composition (`RuntimeModules`), asks them in start order to get going,
/// has the composition's launcher start the game, and stops them in the
/// reverse order. Nothing outside a module asks whether the game is a Wine
/// game: it asks the module that would know. Modules depend on each other
/// at run time — Steam runs in Wine's session, and its output feeds Wine's
/// quit check — so one may ask the set for another by type
/// (`RuntimeModules.module(_:)`). docs/wrapp-launch.md has the order.
protocol RuntimeModule: AnyObject, Sendable {
    nonisolated static var id: ModuleID { get }

    init(config: GameConfig)

    /// Whether it has anything to stop when the wrapp quits
    /// (`finishForQuit`), which then waits for it on a background queue.
    var stopsOnQuit: Bool { get }

    /// The loading window's first stage, when this module is the first
    /// thing a launch waits for (Steam's start); nil leaves the game's.
    func firstStage(gameTitle: String) -> LoadingStage?

    /// Whether the save warning is shown before the game starts, as the
    /// module's `runtime: { save-warning }` says: Wine games show it
    /// (ScummVM is more stable).
    var showsSaveWarning: Bool { get }

    /// Whether a process counts as this launch's progress for the loading
    /// window; nil when the module has no processes to tell apart.
    var ownsProcess: (@Sendable (pid_t) -> Bool)? { get }

    /// Where the player's saves are, as the game sees them: Wine mounts the
    /// folder as A: and links it as the prefix's Documents. Throws with what
    /// to tell the player.
    func connectSaves(_ saves: URL) throws(ModuleFailure)

    /// Arm what watches the game while it runs, before anything starts.
    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?)

    /// Get going behind the save warning: Steam starts and signs in, Wine
    /// starts its desktop. Returns why the game won't be started, if it
    /// won't.
    func prepare(_ launch: LaunchContext) async -> PrepareOutcome

    /// Once the game has ended by itself and anything to show has been:
    /// stop, taking as long as it needs (Steam saves its sign-in).
    func finishAfterGame() async

    /// The wrapp is quitting: stop, briefly. From the cleanup's background
    /// queue, after the modules after this one have.
    nonisolated func finishForQuit(onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?)

    /// The debug menu's shell, for the module that starts the game.
    func launchShell()
}

extension RuntimeModule {
    var stopsOnQuit: Bool { false }
    func firstStage(gameTitle: String) -> LoadingStage? { nil }
    var showsSaveWarning: Bool { Self.id.showsSaveWarning }
    var ownsProcess: (@Sendable (pid_t) -> Bool)? { nil }
    func connectSaves(_ saves: URL) throws(ModuleFailure) {}
    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?) {}
    func prepare(_ launch: LaunchContext) async -> PrepareOutcome { .ready }
    func finishAfterGame() async {}
    nonisolated func finishForQuit(onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?) {}
    func launchShell() {}
}

/// The module that starts the game: the composition's launcher.
protocol GameStarting: RuntimeModule {
    /// What it runs, for the log and the debug window.
    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo

    /// Start the game. `gamePid` is 0 and `process` nil when something else
    /// (Steam) starts it, to be found by `gameExeName`.
    func startGame(_ launch: LaunchContext) async -> LaunchResult

    /// How the game is found once started: a Wine program by its .exe's
    /// name (the launcher's process is only Wine's), or the launcher's own
    /// process.
    var findsGame: GameDiscovery { get }

    /// For a game started by something else: when to stop waiting for it,
    /// from what is running; nil while it may still come.
    func abandonWaitingIf() -> ((Set<ProcessList.Entry>) -> String?)?

    /// For a game started by something else: called while waiting for it.
    func whileWaitingForGame(_ launch: LaunchContext) -> (() -> Void)?

    /// Whether the game's window may be another process's of the same
    /// exe than the one found first: a game wrapped in Armadillo (Big
    /// Fish's) runs as two, the first running the second under its own
    /// debugger.
    var windowMayBeAnotherProcess: Bool { get }
}

extension GameStarting {
    func abandonWaitingIf() -> ((Set<ProcessList.Entry>) -> String?)? { nil }
    func whileWaitingForGame(_ launch: LaunchContext) -> (() -> Void)? { nil }
    var windowMayBeAnotherProcess: Bool { false }
}

/// How a started game is found and watched.
enum GameDiscovery: Equatable {
    /// A Wine program, by its .exe's name, in this wrapp's Wine; its
    /// window is brought forward once it shows.
    case wineProgram
    /// Started by something other than the wrapp (Steam, Big Fish's DRM), so there is no
    /// launcher process of ours: found by its .exe's name, and given up on
    /// when the starter goes (`abandonWaitingIf`).
    case wineProgramStartedElsewhere
    /// The launcher's own process; the wrapp leaves the Dock once its
    /// window shows, as the game is that process's app.
    case ownProcess
}

/// What starting the game gave.
struct LaunchResult {
    let process: Process?
    let gamePid: Int32
    let gameExeName: String?

    static let failed = LaunchResult(process: nil, gamePid: -1, gameExeName: nil)
}

/// Whether to go on to the game after the modules got going.
enum PrepareOutcome: Equatable {
    case ready
    /// Nothing is to be started, and that's no failure: the player chose it.
    case notStarted
    /// Starting failed, and the player has been told.
    case failedAndTold
}

/// A module's failure, in words for the player, and fixed words for a
/// report. The launcher shows and reports it: a module never does either
/// itself.
struct ModuleFailure: Error {
    /// What was being done, in a report's fixed words ("Mounting the saves folder").
    let what: String
    let error: Error
    let title: String
    let detail: String
}

/// What a launch's modules share: the game's configuration, the loading
/// window, and what to call when the game reports something.
@MainActor final class LaunchContext {
    let config: GameConfig
    let infoWindow: InfoWindowController?
    let watchers: LaunchWatchers
    /// Every module the launch runs, for one to reach another it needs.
    let modules: RuntimeModules
    /// Reports a failure the player has been shown.
    let report: (FailureReport) -> Void

    init(config: GameConfig, infoWindow: InfoWindowController?, watchers: LaunchWatchers,
         modules: RuntimeModules, report: @escaping (FailureReport) -> Void) {
        self.config = config
        self.infoWindow = infoWindow
        self.watchers = watchers
        self.modules = modules
        self.report = report
    }
}

/// What watches the game while it runs: each module arms what it needs
/// (`RuntimeModule.armWatchers`), and every line any module's processes
/// print reaches all of them, so Steam's output feeds Wine's quit check.
/// Read from the threads reading output once armed, and never changed
/// after.
nonisolated final class LaunchWatchers: @unchecked Sendable {
    var helperReport: InProcessHelperReport?
    var quitCheck: GameQuitCheck?
    var copyProtection: CopyProtection?
    let noDisplay: NoDisplaySignal
    let activity: LaunchActivityMonitor?

    init(onNoDisplay: (@Sendable (String) -> Void)?, activity: LaunchActivityMonitor?) {
        noDisplay = NoDisplaySignal(onFirst: onNoDisplay)
        self.activity = activity
    }

    /// One line of output from the game or what started it.
    func observe(line: String) {
        helperReport?.observe(line: line)
        quitCheck?.observe(line: line)
        noDisplay.check(line)
        activity?.noteOutput()
    }
}

/// The modules a wrapp's composition has, in start order.
@MainActor final class RuntimeModules {
    let all: [any RuntimeModule]
    let launcher: any GameStarting

    /// Every module the wrapp knows how to run.
    nonisolated static let known: [any RuntimeModule.Type] = [
        WineRuntime.self, SteamRuntime.self, BigFishRuntime.self, ScummVMRuntime.self, DOSBoxRuntime.self,
    ]

    /// The modules `config`'s composition has, or nil when one is a module
    /// this wrapp can't run (a wrapp built by a newer Second Chance).
    init?(config: GameConfig) {
        var all: [any RuntimeModule] = []
        for id in config.composition.modules {
            guard let type = Self.known.first(where: { $0.id == id }) else { return nil }
            all.append(type.init(config: config))
        }
        guard let launcher = all.first(where: { type(of: $0).id == config.composition.launcher }) as? any GameStarting else {
            return nil
        }
        self.all = all
        self.launcher = launcher
    }

    /// The type of the module that starts `composition`'s games.
    nonisolated static func launcher(of composition: Composition) -> (any GameStarting.Type)? {
        known.first { $0.id == composition.launcher } as? any GameStarting.Type
    }

    /// The module of type `M`, when the composition has it.
    func module<M: RuntimeModule>(_: M.Type) -> M? {
        all.lazy.compactMap { $0 as? M }.first
    }
}
