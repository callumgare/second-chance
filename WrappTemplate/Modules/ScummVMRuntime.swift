//
//  ScummVMRuntime.swift
//  WrappTemplate
//
//  The ScummVM module in the wrapp: the game is ScummVM's own process,
//  reading the game's data folder.

import Foundation
import Logging
import SecondChanceKit

/// ScummVM, which runs a game from its data, with no Wine.
final class ScummVMRuntime: GameStarting {
    nonisolated static let id = ModuleID.scummvm

    private let config: GameConfig
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What ScummVM prints: a category of its own.
    private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.ScummVM")

    required init(config: GameConfig) {
        self.config = config
    }

    /// When WrappPuppeteer started the wrapp, what loads the in-process
    /// helpers' puppet control into scummvm, so WrappPuppeteer can capture
    /// and click the game without any permission. Wine games get it through
    /// winemac.so; scummvm is an ordinary binary (ad-hoc signed, no hardened
    /// runtime), so dyld inserts the dylib. The other helpers stay unarmed in
    /// it, since their variables aren't set. Empty for every player's launch.
    /// See docs/wine-in-process-helpers.md.
    private var puppetVariables: [String: String] {
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

    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?) {
        let variables = puppetVariables
        guard !variables.isEmpty else { return }
        watchers.helperReport = InProcessHelperReport(armingVariables: variables, logger: logger)
    }

    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo {
        let layout = WrappLayout(app: config.appPath)
        let scummvmIni = layout.resources.appendingPathComponent("scummvm.ini").path
        // The game's data: where its launch says, in the app; for a wrapp
        // built before launches were recorded, in its prefix, whose copy the
        // wrapp may be running from.
        let dataDir = config.launchRecorded
            ? (layout.location(config.launch.path)?.path ?? config.launch.path)
            : WrappLayout.onDriveC(config.gameInstallerDir, in: config.wine.driveC).path
        // The game its launch names (`nancy:nancy7`), or for an older wrapp,
        // whichever ScummVM detects in the folder.
        let game = config.launch.arguments.first ?? "--auto-detect"
        let arguments = [
            "-f",                                            // Fullscreen
            "--config=\(config.scummvmConfigPath.path)",     // User config file location
            "--initial-cfg=\(scummvmIni)",                   // Configuration template to copy into configPath if there's no existing config
            "--path=\(dataDir)",                             // Game files location
            "--savepath=\(config.appSupportPath.path)",      // Save files location
            game,                                            // The game to start
        ]
        return GameLaunchInfo(
            executable: layout.scummvm.path,
            arguments: arguments,
            workingDirectory: nil,
            gameExeName: nil,  // ScummVM doesn't have a separate game exe
            gameExePath: nil
        )
    }

    var findsGame: GameDiscovery { .ownProcess }

    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = Self.launchInfo(config)

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
        let task = TaggedProcess(logger: outputLogger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        let puppetVariables = puppetVariables
        if !puppetVariables.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(puppetVariables) { $1 }
        }
        let helperReport = launch.watchers.helperReport
        let activity = launch.watchers.activity
        task.onLine = { line in
            helperReport?.observe(line: line)
            activity?.noteOutput()
        }

        do {
            try task.run()
            logger.notice("[ScummVM] Game process started with PID \(task.processIdentifier)")
            return LaunchResult(process: task.process, gamePid: task.processIdentifier, gameExeName: nil)
        } catch {
            logger.critical("ERROR: Failed to launch ScummVM: \(error.localizedDescription)")
            return .failed
        }
    }

    func launchShell() {
        launchScummvmShell(config)
    }
}
