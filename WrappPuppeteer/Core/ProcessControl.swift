//
//  ProcessControl.swift
//  WrappPuppeteer
//
//  Launching, finding, waiting on and killing the processes under test.

import Foundation
import AppKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.ProcessControl")

// MARK: - Cleanup on termination

// Read from the signal handler, so they are plain globals prepared up front:
// nothing in the handler allocates.
private var cleanupAppPid: Int32 = 0
private var cleanupHelperPid: Int32 = 0
private var cleanupPkillArgvs: [[UnsafeMutablePointer<CChar>?]] = []

private func handleTermination(_ sig: Int32) {
    let message = "\n⚠️  Received termination signal - killing processes under test...\n"
    _ = message.withCString { write(STDERR_FILENO, $0, strlen($0)) }

    if cleanupAppPid > 0 { kill(cleanupAppPid, SIGKILL) }
    if cleanupHelperPid > 0 { kill(cleanupHelperPid, SIGKILL) }

    for index in cleanupPkillArgvs.indices {
        var pid: pid_t = 0
        posix_spawn(&pid, "/usr/bin/pkill", nil, nil, &cleanupPkillArgvs[index], nil)
    }

    _exit(143)
}

/// Kills the app under test (and anything it spawned) if WrappPuppeteer is
/// interrupted, so an aborted run doesn't leave it holding the screen.
enum ProcessCleanup {
    /// Install SIGINT/SIGTERM/SIGHUP handlers. `pkillArguments` are extra
    /// `pkill` invocations for helper processes that outlive the app, e.g.
    /// `[["-9", "-f", "wine"]]`.
    static func install(pkillArguments: [[String]]) {
        cleanupPkillArgvs = pkillArguments.map { args in
            (["pkill"] + args).map { strdup($0) } + [nil]
        }
        signal(SIGINT, handleTermination)
        signal(SIGTERM, handleTermination)
        signal(SIGHUP, handleTermination)
        logger.notice("  → Signal handlers installed")
    }

    /// Record the processes to kill. `helperPid` is a second process that
    /// isn't a child of the app, if there is one.
    static func track(appPid: Int32, helperPid: Int32?) {
        cleanupAppPid = appPid
        cleanupHelperPid = helperPid ?? 0
        logger.notice("  → Cleanup tracking app PID \(appPid), helper PID \(cleanupHelperPid)")
    }
}

// MARK: - Finding processes

/// Named to avoid shadowing Foundation.ProcessInfo — this target also compiles
/// Shared/ sources that use the Foundation type.
struct RunningProcess {
    let pid: Int32
    /// Executable basename.
    let name: String
    /// Full command path as `ps` reports it.
    let command: String
}

enum ProcessFinder {
    /// Every process on the system, via `ps`. Sees processes that
    /// NSWorkspace doesn't, such as Wine's.
    static func allProcesses() -> [RunningProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            logger.error("  ⚠️  Error listing processes: \(error)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            let command = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return RunningProcess(pid: pid, name: (command as NSString).lastPathComponent, command: command)
        }
    }

    /// Poll until a process with this executable name (case-insensitive) is running.
    static func waitForProcess(named name: String, timeout: TimeInterval) -> RunningProcess? {
        let start = Date()
        var lastLog = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let match = allProcesses().first(where: { $0.name.lowercased() == name.lowercased() }) {
                logger.notice("✅ \(name) process detected (PID: \(match.pid))")
                return match
            }
            if Date().timeIntervalSince(lastLog) >= 5 {
                logger.notice("   [\(Int(Date().timeIntervalSince(start)))s] Checking for \(name) process...")
                lastLog = Date()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        logger.critical("❌ Timeout: \(name) process not detected")
        return nil
    }
}

// MARK: - App lifecycle

enum ProcessControl {
    /// Launch an app bundle through LaunchServices and wait for it to start.
    static func launch(appPath: String, arguments: [String] = []) -> NSRunningApplication? {
        logger.notice("🚀 Launching \(appPath)...")
        if !arguments.isEmpty {
            logger.notice("   Arguments: \(arguments.joined(separator: " "))")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments

        var app: NSRunningApplication?
        let semaphore = DispatchSemaphore(value: 0)

        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: configuration) { runningApp, error in
            if let error {
                logger.critical("❌ Failed to launch: \(error.localizedDescription)")
            }
            app = runningApp
            semaphore.signal()
        }

        semaphore.wait()
        return app
    }

    /// Whether a PID is alive. `kill(pid, 0)` is used because it is the only
    /// check that's reliable for processes LaunchServices doesn't track.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// True while either the app or the helper process is alive.
    static func isRunning(_ app: NSRunningApplication, helperPid: Int32?) -> Bool {
        let appRunning = isAlive(app.processIdentifier)
        let helperRunning = helperPid.map { isAlive($0) } ?? false
        logger.debug("isRunning: app PID \(app.processIdentifier)=\(appRunning), helper PID \(helperPid ?? -1)=\(helperRunning)")
        return appRunning || helperRunning
    }

    /// Force-terminate the app, then run each `pkill` invocation to catch
    /// helper processes that outlive it.
    static func forceQuit(_ app: NSRunningApplication, pkillArguments: [[String]] = []) {
        logger.warning("⚠️  Force quitting \(app.localizedName ?? "app")...")
        app.forceTerminate()

        for arguments in pkillArguments {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = arguments
            do {
                try pkill.run()
                pkill.waitUntilExit()
            } catch {
                logger.warning("⚠️  pkill \(arguments.joined(separator: " ")) failed: \(error)")
            }
        }
    }

    /// Wait until neither the app nor the helper process is running.
    static func waitForTermination(_ app: NSRunningApplication, helperPid: Int32?, timeout: TimeInterval) -> Bool {
        let start = Date()
        var lastLog = Date()

        if let helperPid {
            logger.notice("   Waiting for helper (PID: \(helperPid)) and app (PID: \(app.processIdentifier)) to exit...")
        } else {
            logger.notice("   Waiting for app (PID: \(app.processIdentifier)) to exit...")
        }

        while Date().timeIntervalSince(start) < timeout {
            if !isRunning(app, helperPid: helperPid) {
                logger.notice("   ✓ Process exited after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return true
            }

            if Date().timeIntervalSince(lastLog) >= 2 {
                var still: [String] = []
                if isAlive(app.processIdentifier) { still.append("app (PID: \(app.processIdentifier))") }
                if let helperPid, isAlive(helperPid) { still.append("helper (PID: \(helperPid))") }
                logger.notice("   [\(String(format: "%.1f", Date().timeIntervalSince(start)))s] Still running: \(still.joined(separator: ", "))")
                lastLog = Date()
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        logger.notice("   ✗ Timeout after \(Int(timeout))s waiting for process to exit")
        return false
    }
}
