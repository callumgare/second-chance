//
//  GameMonitor.swift
//  GameWrapper
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
        return (command as NSString).lastPathComponent
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
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.GameWrapper.GameMonitor")
    
    var exitCode: Int32? {
        exitCodeLock.withLock { _exitCode }
    }
    
    private func setExitCode(_ code: Int32?) {
        exitCodeLock.withLock { _exitCode = code }
    }
    
    init(config: GameConfig, debugMode: Bool = false) {
        self.config = config
        self.gameEngine = config.gameEngine
        self.debugMode = debugMode
    }
    
    // MARK: - Game Lifecycle Monitoring
    
    /// Wait for game to start (works for both Wine and ScummVM games)
    func waitForGameToStart(gameExeName: String, gamePid: Int32, timeout: TimeInterval = 120) -> Int32? {
        switch gameEngine {
        case "wine", _ where gameEngine.hasPrefix("wine-"):
            return waitForWineGameToStart(gameExeName: gameExeName, timeout: timeout)
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
        case "wine", _ where gameEngine.hasPrefix("wine-"):
            waitForWineGameToStop(winePid: gamePid)
        case "scummvm":
            waitForScummVMGameToStop(gamePid: gamePid, process: process)
        default:
            logger.error("[Game Monitor] Unknown game engine: \(self.gameEngine)")
            isMonitoring = false
        }
    }
    
    /// Activate game window and hide wrapper from dock
    func activateGameWindow(gamePid: Int32, infoWindow: InfoWindowController?) {
        waitForWindowAndActivate(pid: gamePid, infoWindow: infoWindow)
    }
    
    // MARK: - Process Detection (Wine Games)
    
    /// Get all Wine-related processes
    func getAllWineProcesses() -> Set<WineProcessInfo> {
        logger.notice("[Wine Processes] Fetching all wine-related processes...")
        
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
                logger.notice("[Wine Processes] Found \(processes.count) wine-related processes: \(pids)")
            }
        } catch {
            logger.error("[Wine Processes] Error checking processes: \(error)")
        }
        
        return processes
    }
    
    /// Wait for Wine game executable to start
    private func waitForWineGameToStart(gameExeName: String, timeout: TimeInterval = 120) -> Int32? {
        logger.notice("[Game Monitor] Waiting for Wine game executable: \(gameExeName)")
        logger.notice("[Game Monitor] Wine prefix: \(self.config.winePrefix.path)")
        
        let startTime = Date()
        var gamePid: Int32? = nil
        
        while Date().timeIntervalSince(startTime) < timeout && gamePid == nil {
            let processes = self.getAllWineProcesses()
            
            for process in processes {
                if process.basename.lowercased() == gameExeName.lowercased() {
                    logger.notice("[Game Monitor] ✅ Game executable started!")
                    logger.notice("[Game Monitor]   - Process: \(process.basename)")
                    logger.notice("[Game Monitor]   - PID: \(process.pid)")
                    logger.notice("[Game Monitor]   - Parent PID: \(process.ppid)")
                    logger.notice("[Game Monitor]   - Full path: \(process.command)")
                    logger.notice("[Game Monitor]   - Time to start: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                    
                    if let pid = Int32(process.pid) {
                        gamePid = pid
                        self.delegate?.gameMonitorDidDetectGameStart(pid: pid)
                    }
                    
                    // Log all related wine processes
                    logger.notice("[Game Monitor] All Wine processes in this session:")
                    for proc in processes.sorted(by: { $0.basename < $1.basename }) {
                        let marker = proc.basename.lowercased() == gameExeName.lowercased() ? " 🎮" : ""
                        logger.notice("[Game Monitor]   - \(proc.basename) (PID \(proc.pid))\(marker)")
                    }
                    
                    break
                }
            }
            
            if gamePid == nil {
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
    private func waitForWindowAndActivate(pid: Int32, infoWindow: InfoWindowController?) {
        logger.notice("[Game Monitor] Monitoring for windows...")
        
        var windowDetected = false
        let windowTimeout: TimeInterval = 30.0 // Wait up to 30 seconds for windows
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
                        Logger(label: "au.gare.callum.second-chance.GameWrapper.GameMonitor").notice("[Game Monitor] Notifying info window that game has loaded...")
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
                        logger.error("[Game Monitor] ⚠️ Failed to activate game process")
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
    }
    
    /// Hide wrapper app from dock
    func hideWrapperFromDock() {
        // Don't hide dock icon in debug mode so log window stays accessible
        guard !debugMode else {
            logger.notice("[Game Monitor] Skipping dock hide (debug mode enabled)")
            return
        }
        
        DispatchQueue.main.async {
            Logger(label: "au.gare.callum.second-chance.GameWrapper.GameMonitor").notice("[Game Monitor] Hiding wrapper app from dock...")
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    // MARK: - Game Stop Monitoring
    
    /// Wait for Wine game to stop
    private func waitForWineGameToStop(winePid: Int32) {
        logger.notice("[Process Monitor] Waiting for Wine game to stop (PID \(winePid))")
        
        var lastProcessList: Set<String> = []
        
        // Give Wine a moment to spawn child processes before first check
        Thread.sleep(forTimeInterval: 2)
        
        logger.notice("[Process Monitor] Beginning process checks...")
        
        while true {
            // Check if main wine process is still running
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
            checkProcess.arguments = ["-p", String(winePid)]
            checkProcess.standardOutput = Pipe()
            checkProcess.standardError = Pipe()
            
            do {
                try checkProcess.run()
                checkProcess.waitUntilExit()
                
                if checkProcess.terminationStatus != 0 {
                    logger.notice("[Process Monitor] Wine process \(winePid) has terminated")
                    // Store exit code - Wine exit codes are typically 0 or non-zero from wineserver
                    self.setExitCode(Int32(checkProcess.terminationStatus))
                    self.isMonitoring = false
                    self.delegate?.gameMonitorGameDidTerminate(exitCode: self.exitCode)
                    break
                }
                
                logger.notice("[Process Monitor] Wine process \(winePid) is still running")
            } catch {
                logger.error("[Process Monitor] Error checking wine process: \(error)")
                self.setExitCode(-1)
                self.isMonitoring = false
                self.delegate?.gameMonitorGameDidTerminate(exitCode: -1)
                break
            }
            
            // Get all wine-related processes
            let wineProcesses = self.getAllWineProcessesDetailed()
            lastProcessList = self.logWineProcesses(wineProcesses, mainWinePid: winePid, lastProcessList: lastProcessList)
            
            // Check every 3 seconds
            Thread.sleep(forTimeInterval: 3)
        }
        
        logger.notice("[Process Monitor] Monitoring stopped")
    }
    
    /// Wait for ScummVM game to stop
    private func waitForScummVMGameToStop(gamePid: Int32, process: Process?) {
        logger.notice("[Process Monitor] Waiting for ScummVM game to stop (PID \(gamePid))")
        
        // If we have the process object, use it directly for better reliability
        if let process = process {
            if process.isRunning {
                process.waitUntilExit()
            }
            logger.notice("[Process Monitor] ScummVM process \(gamePid) has terminated")
            // Capture exit code while we safely have access to the process object
            let exitCode = process.terminationStatus
            self.setExitCode(exitCode)
            logger.notice("[Process Monitor] ScummVM exit code: \(exitCode)")
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
                        self.setExitCode(0)  // Process is gone, assume success
                        break
                    }
                    
                    logger.notice("[Process Monitor] ScummVM process \(gamePid) is still running")
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
        
        logger.notice("[Process Monitor] Fetching process list...")
        
        var wineProcesses: [(pid: String, ppid: String, name: String)] = []
        
        do {
            try psProcess.run()
            logger.notice("[Process Monitor] ps command started, reading output...")
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            logger.notice("[Process Monitor] Read \(data.count) bytes from ps output")
            
            psProcess.waitUntilExit()
            logger.notice("[Process Monitor] ps command completed with status: \(psProcess.terminationStatus)")
            
            if let output = String(data: data, encoding: .utf8) {
                logger.notice("[Process Monitor] Successfully decoded output, parsing lines...")
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
            logger.notice("[Process Monitor] No wine-related processes found")
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
        if currentProcessList != lastProcessList {
            logger.notice("[Process Monitor] Wine processes (\(wineProcesses.count) total):")
            for line in processLines {
                logger.notice("\(line)")
            }
        } else {
            logger.notice("[Process Monitor] Process list unchanged (\(wineProcesses.count) processes)")
        }
        
        return currentProcessList
    }
}
