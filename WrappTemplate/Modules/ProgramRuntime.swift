//
//  ProgramRuntime.swift
//  WrappTemplate
//
//  The core's launch: a program the app carries (`LAUNCH /MacOS/tool`),
//  started as it is, with no engine.

import Foundation
import Logging
import SecondChanceKit

/// Starts a program in the app itself, when no module does: the launch's
/// program is a bare `/…`, a file under the app's `Contents/`, run with the
/// launch's arguments and environment. The game is that process, as a
/// ScummVM or DOSBox game is theirs. It's no module: a composition whose
/// launcher is nil has it (`RuntimeModules`).
final class ProgramRuntime: GameStarting {
    /// Its name in the log and the debug window, where a module's id would be.
    nonisolated static let id = ModuleID(rawValue: Composition.coreTag)

    private let config: GameConfig
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What the program prints: a category of its own.
    private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Program")

    required init(config: GameConfig) {
        self.config = config
    }

    /// The core shows no save warning: that's a module's to ask for.
    var showsSaveWarning: Bool { false }

    /// When WrappPuppeteer started the wrapp, what loads the in-process
    /// helpers' puppet control into the program, as into scummvm and
    /// dosbox. Empty for every player's launch.
    private var puppetVariables: [String: String] {
        guard Wine.puppetDirectory() != nil else { return [:] }
        let dylib = config.appPath.appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib").path
        // dyld kills a process whose inserted dylib is missing, so a wrapp
        // built without it runs the program without puppet control instead.
        guard FileManager.default.fileExists(atPath: dylib) else {
            logger.error("[Helpers] Puppet control can't be loaded into the program: \(dylib) is missing")
            return [:]
        }
        let name = URL(fileURLWithPath: config.launch.program).lastPathComponent
        return ["DYLD_INSERT_LIBRARIES": dylib, "PUPPET_CONTROL_EXE": name]
    }

    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?) {
        let variables = puppetVariables
        guard !variables.isEmpty else { return }
        watchers.helperReport = InProcessHelperReport(armingVariables: variables, logger: logger)
    }

    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo {
        let program = WrappLayout(app: config.appPath).bareLocation(config.launch.program)
        return GameLaunchInfo(
            executable: program?.path ?? config.launch.program,
            arguments: config.launch.arguments,
            workingDirectory: config.appSupportPath.path,  // Where it may write: never the app
            gameExeName: nil,  // The program is its own process
            gameExePath: nil
        )
    }

    var findsGame: GameDiscovery { .ownProcess }

    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = Self.launchInfo(config)
        logger.notice("Launching \(launchInfo.formatLaunchCommand())")
        guard FileManager.default.isExecutableFile(atPath: launchInfo.executable) else {
            logger.critical("ERROR: The program the app starts isn't there, or can't be run: \(launchInfo.executable)")
            return .failed
        }
        do {
            try FileManager.default.createDirectory(at: config.appSupportPath, withIntermediateDirectories: true)
        } catch {
            logger.critical("ERROR: Can't make the folder the program's files go in, \(config.appSupportPath.path): \(error.localizedDescription)")
            return .failed
        }

        let task = TaggedProcess(logger: outputLogger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        task.currentDirectoryURL = config.appSupportPath
        task.environment = ProcessInfo.processInfo.environment
            .merging(config.launch.environment) { $1 }
            .merging(puppetVariables) { $1 }
        let helperReport = launch.watchers.helperReport
        let activity = launch.watchers.activity
        task.onLine = { line in
            helperReport?.observe(line: line)
            activity?.noteOutput()
        }

        do {
            try task.run()
            logger.notice("[Program] Started with PID \(task.processIdentifier)")
            return LaunchResult(process: task.process, gamePid: task.processIdentifier, gameExeName: nil)
        } catch {
            logger.critical("ERROR: Failed to start \(launchInfo.executable): \(error.localizedDescription)")
            return .failed
        }
    }

    func launchShell() {
        logger.notice("A program the app starts itself has no shell to open")
    }
}
