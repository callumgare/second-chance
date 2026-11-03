//
//  DOSBoxRuntime.swift
//  WrappTemplate
//
//  The DOSBox module in the wrapp: the game is DOSBox Staging's own
//  process, running the game's DOS program.

import Foundation
import Logging
import SecondChanceKit

/// DOSBox Staging, which runs a DOS game from its folder, with no Wine. The
/// game's folder is its C: drive, read from the wrapp, with what the game
/// writes (its saves and settings) laid over it from the saves volume
/// (`mount -t overlay`), so the wrapp itself is never written to.
final class DOSBoxRuntime: GameStarting {
    nonisolated static let id = ModuleID.dosbox

    private let config: GameConfig
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What DOSBox prints: a category of its own.
    private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.DOSBox")

    required init(config: GameConfig) {
        self.config = config
    }

    /// When WrappPuppeteer started the wrapp, what loads the in-process
    /// helpers' puppet control into dosbox, as into scummvm: an ordinary
    /// binary, signed ad hoc with no hardened runtime when it was prepared,
    /// so dyld inserts the dylib. Empty for every player's launch.
    private var puppetVariables: [String: String] {
        guard Wine.puppetDirectory() != nil else { return [:] }
        let dylib = config.appPath.appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib").path
        // dyld kills a process whose inserted dylib is missing, so a wrapp
        // built without it runs the game without puppet control instead.
        guard FileManager.default.fileExists(atPath: dylib) else {
            logger.error("[Helpers] Puppet control can't be loaded into dosbox: \(dylib) is missing")
            return [:]
        }
        return ["DYLD_INSERT_LIBRARIES": dylib, "PUPPET_CONTROL_EXE": "dosbox"]
    }

    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?) {
        let variables = puppetVariables
        guard !variables.isEmpty else { return }
        watchers.helperReport = InProcessHelperReport(armingVariables: variables, logger: logger)
    }

    /// A path as a DOS command line quotes it.
    nonisolated static func quoted(_ path: String) -> String {
        "\"" + path + "\""
    }

    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo {
        let layout = WrappLayout(app: config.appPath)
        // DOSBox's C: is the C: the game sees, a folder of its own in the
        // wrapp; the program is at its DOS path on it (`/TYRIAN/TYRIAN2K.EXE`).
        let parts = config.gameExePath.split(separator: "/").map(String.init)
        let folder = "\\" + parts.dropLast().joined(separator: "\\")
        let writes = config.appSupportPath.path
        let arguments = [
            "--noprimaryconf",                               // None of the person's own DOSBox settings
            "--nolocalconf",
            "--working-dir", writes,                         // Where DOSBox may write (its captures)
            "--fullscreen",
            "-c", "mount c \(quoted(layout.dosboxC.path))",  // DOSBox's C:, in the wrapp
            "-c", "mount c \(quoted(writes)) -t overlay",    // What it writes, kept outside the wrapp
            "-c", "c:",
            "-c", "cd \(folder)",                            // The program's folder, as DOS names it
            "-c", parts.last ?? "",
            "--exit",                                        // Quit when the game does
        ]
        return GameLaunchInfo(
            executable: layout.dosbox.path,
            arguments: arguments,
            workingDirectory: writes,
            gameExeName: nil,  // DOSBox runs the game in its own process
            gameExePath: nil
        )
    }

    var findsGame: GameDiscovery { .ownProcess }

    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = Self.launchInfo(config)
        logger.notice("Launching DOSBox: \(launchInfo.formatLaunchCommand())")
        do {
            try FileManager.default.createDirectory(at: config.appSupportPath, withIntermediateDirectories: true)
        } catch {
            logger.critical("ERROR: Can't make the folder the game's saves go in, \(config.appSupportPath.path): \(error.localizedDescription)")
            return .failed
        }

        let task = TaggedProcess(logger: outputLogger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        task.currentDirectoryURL = config.appSupportPath
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
            logger.notice("[DOSBox] Game process started with PID \(task.processIdentifier)")
            return LaunchResult(process: task.process, gamePid: task.processIdentifier, gameExeName: nil)
        } catch {
            logger.critical("ERROR: Failed to launch DOSBox: \(error.localizedDescription)")
            return .failed
        }
    }

    func launchShell() {
        logger.notice("A DOSBox game has no shell to open")
    }
}
