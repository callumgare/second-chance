//
//  GameMonitor.swift
//  WrappTemplate
//
//  Game process monitoring for Nancy Drew game wrappers

import Foundation
import AppKit
import Logging
import SecondChanceKit
import GameCatalog

// MARK: - Game Monitor Delegate

// MARK: - Game Monitor

class GameMonitor {
    private let config: GameConfig
    private let gameEngine: GameInfo.GameEngine
    private var isMonitoring = false
    private let debugMode: Bool
    private let exitCodeLock = NSLock()
    private var _exitCode: Int32?
    private var _exitSignal: Int32?
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameMonitor")

    var exitCode: Int32? {
        exitCodeLock.withLock { _exitCode }
    }

    /// The signal that killed the game's launcher, when one did; `exitCode`
    /// then holds the signal number too.
    var exitSignal: Int32? {
        exitCodeLock.withLock { _exitSignal }
    }

    private func setExitCode(_ code: Int32?, signal: Int32? = nil) {
        exitCodeLock.withLock {
            _exitCode = code
            _exitSignal = signal
        }
    }

    /// Record how `process` ended: its exit status, or the signal that killed it.
    private func setExit(from process: Process) {
        if process.terminationReason == .uncaughtSignal {
            setExitCode(process.terminationStatus, signal: process.terminationStatus)
        } else {
            setExitCode(process.terminationStatus)
        }
    }

    init(config: GameConfig, debugMode: Bool = false) {
        self.config = config
        self.gameEngine = config.gameEngine
        self.debugMode = debugMode
    }

    // MARK: - Game Lifecycle Monitoring

    /// Wait for game to start (works for both Wine and ScummVM games)
    /// `launcher` is the `wine start` process: if it exits before the game's
    /// exe appears, the game never started and there is nothing to wait for.
    /// Without one (Steam starts the game), `abandonIf` says when there is
    /// nothing left to wait for: it sees each check's Wine processes, and
    /// returns why when the game can no longer start. There is no time limit:
    /// a launch that may still work is waited for until the player gives up.
    func waitForGameToStart(gameExeName: String, gamePid: Int32, launcher: Process? = nil,
                            abandonIf: ((Set<ProcessList.Entry>) -> String?)? = nil,
                            whileWaiting: (() -> Void)? = nil) -> Int32? {
        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            return waitForWineGameToStart(gameExeName: gameExeName, launcher: launcher, abandonIf: abandonIf, whileWaiting: whileWaiting)
        case .scummvm:
            return waitForScummVMGameToStart(gamePid: gamePid)
        }
    }

    /// Wait for game to stop (works for both Wine and ScummVM games)
    func waitForGameToStop(gamePid: Int32, process: Process? = nil) {
        guard !isMonitoring else {
            logger.notice("[Game Monitor] Already monitoring, skipping duplicate start")
            return
        }

        isMonitoring = true

        switch gameEngine {
        case .wine, .wineSteam, .wineSteamSilent:
            waitForWineGameToStop(winePid: gamePid, process: process)
        case .scummvm:
            waitForScummVMGameToStop(gamePid: gamePid, process: process)
        }
    }

    /// Waits for the game's first window and activates it, for as long as
    /// the game runs. Returns whether a window appeared: false when the game
    /// exited first.
    @discardableResult
    func activateGameWindow(gamePid: Int32, infoWindow: InfoWindowController?) -> Bool {
        waitForWindowAndActivate(pid: gamePid, infoWindow: infoWindow)
    }

    // MARK: - Process Detection (Wine Games)

    /// Wine's processes, the game among them.
    func getAllWineProcesses() -> Set<ProcessList.Entry> {
        guard let processes = ProcessList.current() else {
            logger.error("[Wine Processes] Couldn't list processes")
            return []
        }
        let wine = Set(processes.wine)
        let pids = wine.map { String($0.pid) }.sorted().joined(separator: ", ")
        logger.debug("[Wine Processes] Found \(wine.count) wine-related processes: \(pids)")
        return wine
    }

    /// Wait for Wine game executable to start
    /// `whileWaiting` runs on every check (about twice a second) until the
    /// game appears: what else the launcher wants to watch meanwhile.
    private func waitForWineGameToStart(gameExeName: String, launcher: Process?,
                                        abandonIf: ((Set<ProcessList.Entry>) -> String?)?,
                                        whileWaiting: (() -> Void)? = nil) -> Int32? {
        logger.notice("[Game Monitor] Waiting for Wine game executable: \(gameExeName)")
        logger.debug("[Game Monitor] Wine prefix: \(self.config.winePrefix.path)")

        let startTime = Date()
        var gamePid: Int32?

        while gamePid == nil {
            if let launcher, !launcher.isRunning {
                setExit(from: launcher)
                let how = launcher.terminationReason == .uncaughtSignal
                    ? "was killed by \(SubprocessWatch.signalName(launcher.terminationStatus))"
                    : "exited \(launcher.terminationStatus)"
                let ran = SubprocessWatch.duration(Date().timeIntervalSince(startTime))
                logger.error("[Game Monitor] Wine's launcher \(how) after \(ran) and \(gameExeName) never appeared — the game did not start")
                return nil
            }
            let processes = self.getAllWineProcesses()

            // Not another session's copy of the game: one a killed session
            // left behind, or another copy of this wrapp's.
            let server = config.wine.server
            for process in processes where process.name.lowercased() == gameExeName.lowercased()
                && !server.isElsewhere(process.pid) {
                logger.notice("[Game Monitor] ✅ \(process.name) started (pid \(process.pid)) after \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                logger.debug("[Game Monitor]   parent pid \(process.parent), path \(process.command)")

                gamePid = process.pid

                // Log all related wine processes
                let list = processes.sorted(by: { $0.name < $1.name })
                    .map { "  - \($0.name) (PID \($0.pid))\($0.name.lowercased() == gameExeName.lowercased() ? " 🎮" : "")" }
                    .joined(separator: "\n")
                logger.debug("[Game Monitor] All Wine processes in this session:\n\(list)")

                break
            }

            if gamePid == nil {
                if let reason = abandonIf?(processes) {
                    let waited = SubprocessWatch.duration(Date().timeIntervalSince(startTime))
                    logger.error("[Game Monitor] Stopped waiting for \(gameExeName) after \(waited): \(reason)")
                    return nil
                }
                whileWaiting?()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        return gamePid
    }

    /// Wait for ScummVM game to start (ScummVM starts immediately)
    private func waitForScummVMGameToStart(gamePid: Int32) -> Int32? {
        logger.notice("[Game Monitor] ScummVM game started with PID \(gamePid)")
        return gamePid
    }

    /// Wait for game window to appear and activate it
    private func waitForWindowAndActivate(pid: Int32, infoWindow: InfoWindowController?) -> Bool {
        logger.notice("[Game Monitor] Monitoring for windows...")

        var windowDetected = false
        // For as long as the game runs: on a loaded machine its window has
        // taken minutes, and the game is only brought to the front once it's
        // up. The loading window says meanwhile whether that looks stuck, and
        // the player can give up there.
        let windowStartTime = Date()

        while !windowDetected {
            guard isProcessRunning(pid: pid) else {
                let waited = SubprocessWatch.duration(Date().timeIntervalSince(windowStartTime))
                logger.error("[Game Monitor] The game exited \(waited) into waiting for its window, without showing one")
                return false
            }
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

            let gameWindows = windowList.filter { window in
                if let windowPID = window[kCGWindowOwnerPID as String] as? Int32 {
                    return windowPID == pid
                }
                return false
            }

            if !gameWindows.isEmpty {
                windowDetected = true
                let windowWaitTime = Date().timeIntervalSince(windowStartTime)
                logger.notice("[Game Monitor] ✅ Window detected after \(String(format: "%.1f", windowWaitTime))s")

                // Print window details
                logger.notice("[Game Monitor] Game process windows (\(gameWindows.count)):")
                for (index, window) in gameWindows.enumerated() {
                    let windowName = window[kCGWindowName as String] as? String ?? "(unnamed)"
                    let windowNumber = window[kCGWindowNumber as String] as? Int32 ?? 0
                    let windowLayer = window[kCGWindowLayer as String] as? Int32 ?? 0
                    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                    let width = bounds["Width"] ?? 0
                    let height = bounds["Height"] ?? 0

                    logger.notice("[Game Monitor]   [\(index + 1)] \"\(windowName)\"")
                    logger.notice("[Game Monitor]       Window ID: \(windowNumber)")
                    logger.notice("[Game Monitor]       Size: \(Int(width)) x \(Int(height))")
                    logger.notice("[Game Monitor]       Layer: \(windowLayer)")
                }

                // Notify info window if it exists
                if let infoWindow = infoWindow {
                    DispatchQueue.main.async {
                        Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameMonitor").notice("[Game Monitor] Notifying info window that game has loaded...")
                        infoWindow.notifyGameLoaded()
                    }
                }

                // Activate the game process
                if let gameApp = NSRunningApplication(processIdentifier: pid_t(pid)) {
                    logger.notice("[Game Monitor] Activating game process...")
                    let activated = gameApp.activate(options: [.activateAllWindows])
                    if activated {
                        logger.notice("[Game Monitor] ✅ Game process activated successfully")
                    } else {
                        logger.warning("[Game Monitor] ⚠️ Failed to activate game process")
                    }
                }
                break
            }

            Thread.sleep(forTimeInterval: 0.2) // Check every 200ms
        }
        return windowDetected
    }

    /// Hide the wrapp from the Dock, for a ScummVM game, as it always has:
    /// scummvm's own icon stands for the game. A Wine game's wrapp stays in
    /// the Dock beside Wine's icon for the game, and brings the game forward
    /// when clicked (`GameLauncher.bringGameForward`).
    func hideWrapperFromDock() {
        // Don't hide dock icon in debug mode so log window stays accessible
        guard !debugMode else {
            logger.notice("[Game Monitor] Skipping dock hide (debug mode enabled)")
            return
        }
        DispatchQueue.main.async {
            Logger(label: "au.gare.callum.second-chance.WrappTemplate.GameMonitor").notice("[Game Monitor] Hiding wrapper app from dock...")
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Game Stop Monitoring

    /// Wait for Wine game to stop. With the launcher's `Process`, its exit
    /// status (which `wine start /wait` passes through from the game) or the
    /// signal that killed it is recorded; without one, only that it ended.
    private func waitForWineGameToStop(winePid: Int32, process: Process?) {
        logger.notice("[Process Monitor] Waiting for Wine game to stop (PID \(winePid))")

        var lastProcessList: Set<String> = []

        // Told the moment it exits, so the exit's time is exact: the quit check
        // (GameQuitCheck) measures how soon after a Wine error it came. A
        // process that has already gone can't be watched, so the check below
        // covers one that exited before the source was armed.
        let ended = DispatchSemaphore(value: 0)
        let exitSource = DispatchSource.makeProcessSource(
            identifier: process?.processIdentifier ?? winePid, eventMask: .exit, queue: .global())
        exitSource.setEventHandler { ended.signal() }
        exitSource.resume()
        defer { exitSource.cancel() }

        // The process tree is checked often while the game starts, when it
        // changes and when a launch goes wrong, then once a minute: each
        // check is a `ps`, for as long as the game runs.
        let watchStarted = Date()
        while process?.isRunning ?? isProcessRunning(pid: winePid) {
            let interval: TimeInterval = Date().timeIntervalSince(watchStarted) < 120 ? 3 : 60
            if ended.wait(timeout: .now() + interval) == .success { break }
            // Log the session's process tree when it changes.
            let wineProcesses = self.getAllWineProcessesDetailed()
            lastProcessList = self.logWineProcesses(wineProcesses, mainWinePid: winePid, lastProcessList: lastProcessList)
        }

        if let process {
            // Foundation may not have reaped it yet, and asking a Process it
            // thinks is still running for its exit status throws.
            process.waitUntilExit()
            setExit(from: process)
        } else {
            // No Process to ask, so no exit status to report.
            setExitCode(nil)
        }

        logger.notice("[Process Monitor] Wine process \(winePid) has ended")
        self.isMonitoring = false
    }

    /// Whether a process with this pid exists (`kill(pid, 0)`).
    private func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Wait for ScummVM game to stop
    private func waitForScummVMGameToStop(gamePid: Int32, process: Process?) {
        logger.notice("[Process Monitor] Waiting for ScummVM game to stop (PID \(gamePid))")

        // If we have the process object, use it directly for better reliability
        if let process = process {
            if process.isRunning {
                process.waitUntilExit()
            }
            // Capture how it ended while we safely have access to the process object
            self.setExit(from: process)
            logger.notice("[Process Monitor] ScummVM process \(gamePid) has ended")
        } else {
            // No Process to wait on: watch the pid exit instead.
            let ended = DispatchSemaphore(value: 0)
            let exitSource = DispatchSource.makeProcessSource(identifier: gamePid, eventMask: .exit, queue: .global())
            exitSource.setEventHandler { ended.signal() }
            exitSource.resume()
            while isProcessRunning(pid: gamePid), ended.wait(timeout: .now() + 60) == .timedOut {}
            exitSource.cancel()
            logger.notice("[Process Monitor] ScummVM process \(gamePid) has terminated")
            self.setExitCode(nil)  // Process is gone; its status is unknown
        }

        self.isMonitoring = false
        logger.notice("[Process Monitor] Monitoring stopped")
    }

    /// Wine's processes, for the log of what is running.
    private func getAllWineProcessesDetailed() -> [(pid: String, ppid: String, name: String)] {
        guard let processes = ProcessList.current() else {
            logger.error("[Process Monitor] Couldn't list processes")
            return []
        }
        return processes.wine.map { (pid: String($0.pid), ppid: String($0.parent), name: $0.command) }
    }

    /// Log Wine processes (with change detection)
    private func logWineProcesses(_ wineProcesses: [(pid: String, ppid: String, name: String)], mainWinePid: Int32, lastProcessList: Set<String>) -> Set<String> {
        var currentProcessList: Set<String> = []

        if wineProcesses.isEmpty {
            if !lastProcessList.isEmpty {
                logger.notice("[Process Monitor] No wine-related processes left")
            }
            return currentProcessList
        }

        // Group processes by Wine session
        var sessionGroups: [String: [(pid: String, ppid: String, name: String, basename: String)]] = [:]

        for proc in wineProcesses {
            var sessionId = "unknown"
            var basename = proc.name

            if let range = proc.name.range(of: "/winetemp-[^/]+/") {
                let tempPath = String(proc.name[..<range.upperBound])
                sessionId = tempPath
                basename = String(proc.name[range.upperBound...])
            } else if proc.name.contains("wineserver") {
                sessionId = "wineserver-\(proc.pid)"
                basename = "wineserver"
            } else if proc.name.hasPrefix("/") {
                basename = (proc.name as NSString).lastPathComponent
            }

            if sessionGroups[sessionId] == nil {
                sessionGroups[sessionId] = []
            }
            sessionGroups[sessionId]?.append((pid: proc.pid, ppid: proc.ppid, name: proc.name, basename: basename))
        }

        // Build hierarchical output
        var processLines: [String] = []

        // Sort sessions: main wine session first
        let sortedSessions = sessionGroups.keys.sorted { key1, key2 in
            let hasMainWine1 = sessionGroups[key1]?.contains { $0.pid == String(mainWinePid) } ?? false
            let hasMainWine2 = sessionGroups[key2]?.contains { $0.pid == String(mainWinePid) } ?? false
            if hasMainWine1 && !hasMainWine2 { return true }
            if !hasMainWine1 && hasMainWine2 { return false }
            return key1 < key2
        }

        for sessionId in sortedSessions {
            guard let processes = sessionGroups[sessionId] else { continue }

            let wineserver = processes.first { $0.basename == "wineserver" }
            let mainWine = processes.first { $0.basename == "wine" }
            let gameExe = processes.first { proc in
                let base = proc.basename.lowercased()
                return base.hasSuffix(".exe") &&
                       !base.contains("service") &&
                       !base.contains("winedevice") &&
                       !base.contains("plugplay") &&
                       !base.contains("svchost") &&
                       !base.contains("start") &&
                       !base.contains("explorer") &&
                       !base.contains("rpcss") &&
                       !base.contains("wineboot")
            }

            // Build session header
            if let mainWine = mainWine {
                let wineserverInfo = wineserver.map { " via wineserver \($0.pid)" } ?? ""
                processLines.append("Wine Session (PID \(mainWine.pid)\(wineserverInfo)):")
            } else if let wineserver = wineserver {
                processLines.append("Wine Session (wineserver \(wineserver.pid)):")
            } else {
                processLines.append("Wine Processes:")
            }

            // Sort processes within session
            let sortedProcesses = processes.sorted { proc1, proc2 in
                if proc1.basename == "wine" { return true }
                if proc2.basename == "wine" { return false }
                if proc1.basename == "wineserver" { return true }
                if proc2.basename == "wineserver" { return false }
                if proc1.pid == gameExe?.pid { return true }
                if proc2.pid == gameExe?.pid { return false }
                return proc1.basename < proc2.basename
            }

            // Print processes in session
            for proc in sortedProcesses {
                let isGameExe = proc.pid == gameExe?.pid
                let marker = isGameExe ? " 🎮" : ""
                let procLine = "  ├─ \(proc.basename) (PID \(proc.pid), parent \(proc.ppid))\(marker)"
                processLines.append(procLine)
                currentProcessList.insert(procLine)
            }

            processLines.append("")
        }

        // Only print if the process list has changed
        // One entry, so the tree reads as one block and can't be interleaved.
        if currentProcessList != lastProcessList {
            let tree = processLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            logger.notice("[Process Monitor] Wine processes changed (\(wineProcesses.count) total):\n\(tree)")
        }

        return currentProcessList
    }
}
