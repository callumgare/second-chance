//
//  GameMonitor.swift
//  WrappTemplate
//
//  Game process monitoring for Nancy Drew game wrappers

import Foundation
import AppKit
import Logging

// MARK: - Wine Process Info

struct WineProcessInfo: Hashable {
    let pid: String
    let ppid: String
    let command: String
    
    var basename: String {
        return ProcessName.executable(fromPSCommand: command)
    }
}

// MARK: - Game Monitor Delegate

protocol GameMonitorDelegate: AnyObject {
    func gameMonitorDidDetectGameStart(pid: Int32)
    func gameMonitorDidDetectWindow()
    func gameMonitorGameDidTerminate(exitCode: Int32?)
}

// MARK: - Game Monitor

class GameMonitor {
    weak var delegate: GameMonitorDelegate?
    private let config: GameConfig
    private let gameEngine: String
    private var isMonitoring = false
    private let debugMode: Bool
    private let exitCodeLock = NSLock()
    private var _exitCode: Int32? = nil
    private var _exitSignal: Int32? = nil
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
    func waitForGameToStart(gameExeName: String, gamePid: Int32, launcher: Process? = nil, timeout: TimeInterval = 600,
                            whileWaiting: (() -> Void)? = nil) -> Int32? {
        switch gameEngine {
        case _ where gameEngine == "wine" || gameEngine.hasPrefix("wine-"):
            return waitForWineGameToStart(gameExeName: gameExeName, launcher: launcher, timeout: timeout, whileWaiting: whileWaiting)
        case "scummvm":
            return waitForScummVMGameToStart(gamePid: gamePid)
        default:
            logger.error("[Game Monitor] Unknown game engine: \(self.gameEngine)")
            return nil
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
        case _ where gameEngine == "wine" || gameEngine.hasPrefix("wine-"):
            waitForWineGameToStop(winePid: gamePid, process: process)
        case "scummvm":
            waitForScummVMGameToStop(gamePid: gamePid, process: process)
        default:
            logger.error("[Game Monitor] Unknown game engine: \(self.gameEngine)")
            isMonitoring = false
        }
    }
    
    /// Activate game window and hide wrapper from dock
    /// Waits (up to 30s) for the game's first window and activates it.
    /// Returns whether a window appeared.
    @discardableResult
    func activateGameWindow(gamePid: Int32, infoWindow: InfoWindowController?) -> Bool {
        waitForWindowAndActivate(pid: gamePid, infoWindow: infoWindow)
    }
    
    // MARK: - Process Detection (Wine Games)
    
    /// Get all Wine-related processes
    func getAllWineProcesses() -> Set<WineProcessInfo> {
        
        let psProcess = Process()
        psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProcess.arguments = ["-A", "-o", "pid,ppid,comm"]
        
        let pipe = Pipe()
        psProcess.standardOutput = pipe
        psProcess.standardError = Pipe()
        
        var processes = Set<WineProcessInfo>()
        
        do {
            try psProcess.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            psProcess.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n")
                
                for line in lines {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count >= 3 {
                        let pid = String(parts[0])
                        let ppid = String(parts[1])
                        let command = parts[2...].joined(separator: " ")
                        
                        // Check if this is a wine-related process
                        if command.contains("wine") || command.contains(".exe") {
                            processes.insert(WineProcessInfo(pid: pid, ppid: ppid, command: command))
                        }
                    }
                }
                
                let pids = processes.map { $0.pid }.sorted().joined(separator: ", ")
                logger.debug("[Wine Processes] Found \(processes.count) wine-related processes: \(pids)")
            }
        } catch {
            logger.error("[Wine Processes] Error checking processes: \(error)")
        }
        
        return processes
    }
    
    /// Wait for Wine game executable to start
    /// `whileWaiting` runs on every check (about twice a second) until the
    /// game appears: what else the launcher wants to watch meanwhile.
    private func waitForWineGameToStart(gameExeName: String, launcher: Process?, timeout: TimeInterval = 600,
                                        whileWaiting: (() -> Void)? = nil) -> Int32? {
        logger.notice("[Game Monitor] Waiting for Wine game executable: \(gameExeName)")
        logger.debug("[Game Monitor] Wine prefix: \(self.config.winePrefix.path)")
        
        let startTime = Date()
        var gamePid: Int32? = nil
        
        while Date().timeIntervalSince(startTime) < timeout && gamePid == nil {
            if let launcher, !launcher.isRunning {
                setExit(from: launcher)
                let how = launcher.terminationReason == .uncaughtSignal
                    ? "was killed by \(SubprocessWatch.signalName(launcher.terminationStatus))"
                    : "exited \(launcher.terminationStatus)"
                logger.error("[Game Monitor] Wine's launcher \(how) after \(SubprocessWatch.duration(Date().timeIntervalSince(startTime))) and \(gameExeName) never appeared — the game did not start")
                return nil
            }
            let processes = self.getAllWineProcesses()
            
            for process in processes {
                if process.basename.lowercased() == gameExeName.lowercased() {
                    logger.notice("[Game Monitor] ✅ \(process.basename) started (pid \(process.pid)) after \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                    logger.debug("[Game Monitor]   parent pid \(process.ppid), path \(process.command)")
                    
                    if let pid = Int32(process.pid) {
                        gamePid = pid
                        self.delegate?.gameMonitorDidDetectGameStart(pid: pid)
                    }
                    
                    // Log all related wine processes
                    let list = processes.sorted(by: { $0.basename < $1.basename })
                        .map { "  - \($0.basename) (PID \($0.pid))\($0.basename.lowercased() == gameExeName.lowercased() ? " 🎮" : "")" }
                        .joined(separator: "\n")
                    logger.debug("[Game Monitor] All Wine processes in this session:\n\(list)")
                    
                    break
                }
            }
            
            if gamePid == nil {
                whileWaiting?()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        
        if gamePid == nil {
            logger.error("[Game Monitor] ⚠️ Game executable not detected within \(Int(timeout))s timeout")
        }
        
        return gamePid
    }
    
    /// Wait for ScummVM game to start (ScummVM starts immediately)
    private func waitForScummVMGameToStart(gamePid: Int32) -> Int32? {
        logger.notice("[Game Monitor] ScummVM game started with PID \(gamePid)")
        self.delegate?.gameMonitorDidDetectGameStart(pid: gamePid)
        return gamePid
    }
    
    /// Wait for game window to appear and activate it
    private func waitForWindowAndActivate(pid: Int32, infoWindow: InfoWindowController?) -> Bool {
        logger.notice("[Game Monitor] Monitoring for windows...")
        
        var windowDetected = false
        // Long, because the game is only brought to the front once its window
        // is up: on a loaded machine that has taken almost two minutes, and a
        // window that came after a shorter wait opened behind whatever the
        // user had in front. The wait ends as soon as the window appears.
        let windowTimeout: TimeInterval = 600
        let windowStartTime = Date()
        
        while !windowDetected && Date().timeIntervalSince(windowStartTime) < windowTimeout {
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
                
                // Notify delegate
                self.delegate?.gameMonitorDidDetectWindow()
                
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
        
        if !windowDetected {
            logger.error("[Game Monitor] ⚠️ No windows detected after \(Int(windowTimeout))s timeout")
            // Notify info window even if no windows detected (treat as loaded)
            DispatchQueue.main.async {
                infoWindow?.notifyGameLoaded()
            }
        }
        return windowDetected
    }
    
    /// Hide wrapper app from dock
    func hideWrapperFromDock() {
        // Don't hide dock icon in debug mode so log window stays accessible
        guard !debugMode else {
            logger.notice("[Game Monitor] Skipping dock hide (debug mode enabled)")
            return
        }
        // Debug switch for isolating startup problems: the activation-policy
        // change hands activation to the Wine process mid-launch.
        guard ProcessInfo.processInfo.environment["SECOND_CHANCE_KEEP_IN_DOCK"] != "1" else {
            logger.notice("[Game Monitor] Skipping dock hide (SECOND_CHANCE_KEEP_IN_DOCK=1)")
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

        while process?.isRunning ?? isProcessRunning(pid: winePid) {
            if ended.wait(timeout: .now() + 3) == .success { break }
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
        self.delegate?.gameMonitorGameDidTerminate(exitCode: self.exitCode)
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
            // Fallback: poll using ps if we don't have the process object
            while true {
                let checkProcess = Process()
                checkProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
                checkProcess.arguments = ["-p", String(gamePid)]
                checkProcess.standardOutput = Pipe()
                checkProcess.standardError = Pipe()
                
                do {
                    try checkProcess.run()
                    checkProcess.waitUntilExit()
                    
                    if checkProcess.terminationStatus != 0 {
                        logger.notice("[Process Monitor] ScummVM process \(gamePid) has terminated")
                        self.setExitCode(nil)  // Process is gone; its status is unknown
                        break
                    }
                    
                } catch {
                    logger.error("[Process Monitor] Error checking ScummVM process: \(error)")
                    self.setExitCode(-1)
                    break
                }
                
                // Check every 3 seconds
                Thread.sleep(forTimeInterval: 3)
            }
        }
        
        self.isMonitoring = false
        self.delegate?.gameMonitorGameDidTerminate(exitCode: self.exitCode)
        logger.notice("[Process Monitor] Monitoring stopped")
    }
    
    /// Get detailed Wine process information for monitoring
    private func getAllWineProcessesDetailed() -> [(pid: String, ppid: String, name: String)] {
        let psProcess = Process()
        psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProcess.arguments = ["-A", "-o", "pid,ppid,comm"]
        
        let pipe = Pipe()
        psProcess.standardOutput = pipe
        psProcess.standardError = Pipe()
        
        
        var wineProcesses: [(pid: String, ppid: String, name: String)] = []
        
        do {
            try psProcess.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            psProcess.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n")
                
                for line in lines {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count >= 3 {
                        let pid = String(parts[0])
                        let ppid = String(parts[1])
                        let name = parts[2...].joined(separator: " ")
                        
                        // Check if this is a wine-related process
                        if name.contains("wine") || name.contains("Game.exe") || name.contains(".exe") {
                            wineProcesses.append((pid: pid, ppid: ppid, name: name))
                        }
                    }
                }
            }
        } catch {
            logger.error("[Process Monitor] Error checking processes: \(error)")
        }
        
        return wineProcesses
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
