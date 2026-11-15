//
//  BasiliskRuntime.swift
//  WrappTemplate
//
//  The basilisk module in the wrapp: the game is Basilisk II's own process,
//  an emulated 68k Mac booting System 7.5.3 and running the program.

import Foundation
import Logging
import SecondChanceKit
import Synchronization

/// Basilisk II, which runs a classic Mac program on an emulated 68040 Mac.
/// Its settings are a prefs file written at each launch, in the program's
/// folder of the person's files: the ROM and the Mac's CD from the app, and
/// the startup disk, the Mac's own, kept with the person's files so what the
/// program saves there (its Preferences) survives, and the app is never
/// written to.
final class BasiliskRuntime: GameStarting {
    nonisolated static let id = ModuleID.basilisk

    private let config: GameConfig
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameLauncher")
    /// What Basilisk II prints: a category of its own.
    private nonisolated let outputLogger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Basilisk")

    /// Basilisk II's process, once started, for ending it on quit.
    private let emulator = Mutex<pid_t?>(nil)
    /// The socket the helper shows the Mac's screen through, and the window
    /// it's shown in (MacScreenWindow), for a launch that shows it there.
    private let screenServer = Mutex<MacScreenServer?>(nil)
    private var screenWindow: MacScreenWindowController?
    /// Told when Basilisk II exits, to end the screen's socket.
    private var exitWatch: DispatchSourceProcess?

    required init(config: GameConfig) {
        self.config = config
    }

    var stopsOnQuit: Bool { true }

    /// The wrapp is quitting while the Mac still runs: the Mac is shut down
    /// as its Special ▸ Shut Down does (SIGUSR2 to `basilisk_mac.m`), so
    /// its disk, the person's files on it, is left clean and Basilisk II
    /// exits. Only a Mac that hasn't shut down in 20 s is ended, never left
    /// running behind the app (the next launch marks its disk clean).
    nonisolated func finishForQuit(onQuitStep: (@Sendable (InfoWindowViewModel.QuitStep) -> Void)?) {
        guard let pid = emulator.withLock({ $0 }), kill(pid, 0) == 0 else { return }
        kill(pid, SIGUSR2)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 {
            logger.warning("[Basilisk] The Mac didn't shut down: ending Basilisk II")
            kill(pid, SIGKILL)
        } else {
            logger.notice("[Basilisk] The Mac shut down")
        }
        // Only now: the helper takes its socket closing as the wrapp gone,
        // and shuts the Mac down without waiting.
        screenServer.withLock { $0 }?.close()
    }

    /// Where the build left the Mac's files in the app (`BASILISK.SETUP`, `CDROM`).
    nonisolated static func folder(_ config: GameConfig) -> URL {
        config.appPath.appendingPathComponent("Contents/SharedSupport/basilisk")
    }

    /// The Mac's startup disk as the person's: a copy of the app's, made on
    /// the first launch, in the program's folder of the person's files.
    nonisolated static func bootDisk(_ config: GameConfig) -> URL {
        config.appSupportPath.appendingPathComponent("boot.hfv")
    }

    /// The prefs file Basilisk II is started with.
    nonisolated static func prefsFile(_ config: GameConfig) -> URL {
        config.appSupportPath.appendingPathComponent("basilisk.prefs")
    }

    /// The Mac's screen, as the launch asks (`--basilisk.screen=640x480x8`):
    /// width, height and colour depth.
    nonisolated static func screen(_ config: GameConfig) -> (width: Int, height: Int, depth: Int) {
        let parts = (config.launch.options["basilisk.screen"] ?? "").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 3 else { return (640, 480, 8) }
        return (parts[0], parts[1], parts[2])
    }

    /// Basilisk II's prefs: a 68040 Mac (`modelid 14`, a Quadra 900 to Mac
    /// OS) with 64 MB, in a window of the program's screen, its own GUI off.
    /// `delay` gives the emulated CPU's thread a pause every 64k
    /// instructions: without it, it starves the sound callback and the 60 Hz
    /// tick QuickTime's clock runs on, and a movie stops on its first frame.
    /// No JIT: it crashes under Rosetta, and Apple silicon has none.
    nonisolated static func prefs(_ config: GameConfig) -> String {
        let folder = folder(config)
        let screen = screen(config)
        let discs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("cdrom-") && $0.hasSuffix(".iso") }.sorted()
        var lines = [
            "rom \(folder.appendingPathComponent("mac.rom").path)",
            "disk \(bootDisk(config).path)",
        ]
        lines += discs.map { "cdrom \(folder.appendingPathComponent($0).path)" }
        lines += [
            "screen win/\(screen.width)/\(screen.height)",
            "displaycolordepth \(screen.depth)",
            "ramsize \(64 << 20)",
            "modelid 14",
            "cpu 4",
            "fpu true",
            "jit false",
            "nogui true",
            "nosound false",
            "frameskip 0",
            "ignoresegv true",
            "idlewait true",
            "delay 500",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// What loads the in-process helpers into Basilisk II (signed ad hoc
    /// when it was prepared, so dyld inserts the dylib): on every launch,
    /// `basilisk_mac.m`, which gets the Mac's window drawing and shuts the Mac
    /// down when the wrapp quits, and when its program quits if the launch
    /// says so (`--basilisk.shut-down=with-program`), and hides the Mac's own
    /// screens, black until its program shows and again once it has quit, if
    /// the launch says so (`--basilisk.mac=hidden`); when WrappPuppeteer started the wrapp,
    /// puppet control too, as in dosbox.
    private var helperVariables: [String: String] {
        let dylib = config.appPath.appendingPathComponent("Contents/Frameworks/in_process_helpers.dylib").path
        // dyld kills a process whose inserted dylib is missing.
        guard FileManager.default.fileExists(atPath: dylib) else {
            logger.error("[Helpers] The in-process helpers can't be loaded into Basilisk II: \(dylib) is missing")
            return [:]
        }
        var variables = ["DYLD_INSERT_LIBRARIES": dylib, "BASILISK_MAC_EXE": "BasiliskII"]
        switch config.launch.options["basilisk.shut-down"] {
        case nil: break
        case "with-program": variables["BASILISK_MAC_SHUT_DOWN_WITH_PROGRAM"] = "1"
        case let other?: logger.warning("[Basilisk] Unknown --basilisk.shut-down=\(other): the Mac stays up when its program quits")
        }
        switch config.launch.options["basilisk.mac"] {
        case nil, "shown": break
        case "hidden": variables["BASILISK_MAC_HIDDEN"] = "1"
        case let other?: logger.warning("[Basilisk] Unknown --basilisk.mac=\(other): the Mac's own screens are shown")
        }
        if Wine.puppetDirectory() != nil { variables["PUPPET_CONTROL_EXE"] = "BasiliskII" }
        return variables
    }

    /// Whether the Mac is shown in the wrapp's own window (MacScreenWindow)
    /// rather than Basilisk II's: unless `SECOND_CHANCE_BASILISK_DISPLAY=0`.
    private nonisolated static var showsMacInWrapp: Bool {
        ProcessInfo.processInfo.environment["SECOND_CHANCE_BASILISK_DISPLAY"] != "0"
    }

    /// The socket and window that show the Mac, ready for the helper; its
    /// variable, or none when Basilisk II's own window is to show it.
    private func prepareScreen() -> [String: String] {
        guard Self.showsMacInWrapp else {
            logger.notice("[Basilisk] SECOND_CHANCE_BASILISK_DISPLAY=0: Basilisk II's own window shows the Mac")
            return [:]
        }
        do {
            let server = try MacScreenServer()
            screenServer.withLock { $0 = server }
            let window = MacScreenWindowController(server: server, title: config.gameTitle)
            window.start()
            screenWindow = window
            return ["BASILISK_MAC_DISPLAY": server.socketPath]
        } catch {
            logger.error("[Basilisk] Basilisk II's own window shows the Mac: \(error)")
            return [:]
        }
    }

    func waitUntilShownInWrapp() async -> Bool? {
        guard let screenWindow else { return nil }
        return await screenWindow.waitUntilShown()
    }

    /// The screen's socket ended once Basilisk II has: a helper that never
    /// connected leaves nothing else to end the wait for it.
    private func watchForExit(_ pid: pid_t) {
        guard let server = screenServer.withLock({ $0 }) else { return }
        exitWatch = Self.exitWatch(pid, closing: server, logger: logger)
    }

    /// Made here, nonisolated: a handler made in main-actor code would be
    /// the main actor's, and run on the source's queue it stops the wrapp
    /// with SIGILL.
    private nonisolated static func exitWatch(_ pid: pid_t, closing server: MacScreenServer, logger: Logger) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            logger.notice("[Basilisk] Basilisk II has exited: closing the Mac's screen")
            server.close()
            source.cancel()
        }
        source.resume()
        // Gone (and reaped) before the watch began: it would never fire.
        if kill(pid, 0) != 0 { server.close() }
        return source
    }

    func armWatchers(_ watchers: LaunchWatchers, gameExe: URL?) {
        let variables = helperVariables
        guard variables["PUPPET_CONTROL_EXE"] != nil else { return }
        watchers.helperReport = InProcessHelperReport(armingVariables: variables, logger: logger)
    }

    nonisolated static func launchInfo(_ config: GameConfig) -> GameLaunchInfo {
        GameLaunchInfo(
            executable: config.appPath.appendingPathComponent("Contents/MacOS/BasiliskII").path,
            arguments: ["--config", prefsFile(config).path],
            workingDirectory: config.appSupportPath.path,
            gameExeName: nil,  // Basilisk II runs the program in its own process
            gameExePath: nil
        )
    }

    var findsGame: GameDiscovery { .ownProcess }

    /// The person's folder, their copy of the startup disk (the app's, the
    /// first time), and this launch's prefs.
    private func prepareFiles() throws {
        let files = FileManager.default
        try files.createDirectory(at: config.appSupportPath, withIntermediateDirectories: true)
        let disk = Self.bootDisk(config)
        if !files.fileExists(atPath: disk.path) {
            try files.copyItem(at: Self.folder(config).appendingPathComponent("boot.hfv"), to: disk)
            logger.notice("[Basilisk] The Mac's startup disk is now the person's: \(disk.path)")
        }
        Self.markCleanlyUnmounted(disk, logger: logger)
        try Self.prefs(config).write(to: Self.prefsFile(config), atomically: true, encoding: .utf8)
    }

    /// The startup disk marked as shut down cleanly, as Mac OS marks it at
    /// Shut Down: after a launch that ended otherwise (the app quit while the
    /// Mac ran), the next boot would say the Mac "may not have been shut
    /// down properly" and hold up its startup items until someone clicks OK.
    /// The bit is the HFS Master Directory Block's `drAtrb` bit 8, at byte
    /// 1034 of a bare HFS volume (`BD` at 1024); anything else is left alone.
    nonisolated static func markCleanlyUnmounted(_ disk: URL, logger: Logger) {
        guard let handle = try? FileHandle(forUpdating: disk) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 1024)
            guard let header = try handle.read(upToCount: 12), header.count == 12,
                  header[0] == 0x42, header[1] == 0x44 else { return }
            let attributes = UInt16(header[10]) << 8 | UInt16(header[11])
            guard attributes & 0x0100 == 0 else { return }
            let marked = attributes | 0x0100
            try handle.seek(toOffset: 1034)
            try handle.write(contentsOf: Data([UInt8(marked >> 8), UInt8(marked & 0xFF)]))
            logger.notice("[Basilisk] The Mac's disk wasn't shut down cleanly last time: marked clean")
        } catch {
            logger.warning("[Basilisk] Couldn't check the Mac's disk was left clean: \(error)")
        }
    }

    func startGame(_ launch: LaunchContext) async -> LaunchResult {
        let launchInfo = Self.launchInfo(config)
        logger.notice("Launching Basilisk II: \(launchInfo.formatLaunchCommand())")
        do {
            try prepareFiles()
        } catch {
            logger.critical("ERROR: Can't set up the Mac's files in \(config.appSupportPath.path): \(error.localizedDescription)")
            return .failed
        }

        let task = TaggedProcess(logger: outputLogger)
        task.executableURL = URL(fileURLWithPath: launchInfo.executable)
        task.arguments = launchInfo.arguments
        task.currentDirectoryURL = config.appSupportPath
        var variables = helperVariables
        if !variables.isEmpty { variables.merge(prepareScreen()) { $1 } }
        task.environment = ProcessInfo.processInfo.environment.merging(variables) { $1 }
        let helperReport = launch.watchers.helperReport
        let activity = launch.watchers.activity
        task.onLine = { line in
            helperReport?.observe(line: line)
            activity?.noteOutput()
        }

        do {
            try task.run()
            logger.notice("[Basilisk] Started with PID \(task.processIdentifier)")
            let pid = task.processIdentifier
            emulator.withLock { $0 = pid }
            watchForExit(pid)
            return LaunchResult(process: task.process, gamePid: task.processIdentifier, gameExeName: nil)
        } catch {
            logger.critical("ERROR: Failed to launch Basilisk II: \(error.localizedDescription)")
            screenServer.withLock { $0 }?.close()
            return .failed
        }
    }

    func launchShell() {
        logger.notice("A classic Mac game has no shell to open")
    }
}
