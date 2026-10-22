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
private var cleanupCommandArgvs: [[UnsafeMutablePointer<CChar>?]] = []

private func handleTermination(_ sig: Int32) {
    let message = "\n⚠️  Received termination signal - killing processes under test...\n"
    _ = message.withCString { write(STDERR_FILENO, $0, strlen($0)) }

    if cleanupAppPid > 0 { kill(cleanupAppPid, SIGKILL) }
    if cleanupHelperPid > 0 { kill(cleanupHelperPid, SIGKILL) }

    for index in cleanupCommandArgvs.indices {
        guard let path = cleanupCommandArgvs[index].first ?? nil else { continue }
        var pid: pid_t = 0
        posix_spawn(&pid, path, nil, nil, &cleanupCommandArgvs[index], nil)
    }

    _exit(143)
}

/// Kills the app under test (and anything it spawned) if WrappPuppeteer is
/// interrupted, so an aborted run doesn't leave it holding the screen.
enum ProcessCleanup {
    /// Install SIGINT/SIGTERM/SIGHUP handlers. `cleanupCommands` are run
    /// after the app is killed, for helper processes that outlive it: each a
    /// whole argv with an absolute path first, e.g. `["/usr/bin/pkill", "-9", "scummvm"]`.
    static func install(cleanupCommands: [[String]]) {
        cleanupCommandArgvs = cleanupCommands.map { argv in
            argv.map { strdup($0) } + [nil]
        }
        signal(SIGINT, handleTermination)
        signal(SIGTERM, handleTermination)
        signal(SIGHUP, handleTermination)
        logger.notice("  → Signal handlers installed")
    }

    /// Clean up as for a termination signal once `pid` has gone. Whoever
    /// starts WrappPuppeteer through LaunchServices isn't its parent —
    /// launchd is — so without this, stopping or crashing the run that
    /// started it would leave it, and the app under test, running.
    static func watchParent(_ pid: Int32) {
        let watcher = Thread {
            // EPERM: alive, just not ours to signal.
            while kill(pid, 0) == 0 || errno == EPERM {
                Thread.sleep(forTimeInterval: 1)
            }
            logger.warning("The process that started WrappPuppeteer (pid \(pid)) has gone; stopping what it was testing")
            handleTermination(SIGHUP)
        }
        watcher.name = "parent watcher"
        watcher.start()
        logger.notice("  → Watching the process that started WrappPuppeteer (pid \(pid))")
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
            return RunningProcess(pid: pid, name: ProcessName.executable(fromPSCommand: command), command: command)
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
    ///
    /// Always a new process. LaunchServices otherwise hands back an instance
    /// of the same bundle ID that is already running — one left over from an
    /// earlier run, say, sitting on an error window — and the run then tests
    /// that instead, which never starts the game. Any such leftover is killed
    /// first.
    static func launch(appPath: String, arguments: [String] = [], environment: [String: String] = [:]) -> NSRunningApplication? {
        logger.notice("🚀 Launching \(appPath)...")
        if !arguments.isEmpty {
            logger.notice("   Arguments: \(arguments.joined(separator: " "))")
        }

        if let bundleID = Bundle(path: appPath)?.bundleIdentifier {
            for leftover in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                let launched = leftover.launchDate.map { "\($0)" } ?? "at an unknown time"
                logger.warning("⚠️  \(bundleID) is already running (PID \(leftover.processIdentifier), launched \(launched)) — killing it first")
                kill(leftover.processIdentifier, SIGKILL)
                _ = waitForExit(leftover.processIdentifier, timeout: 5)
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.environment = environment

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

    /// Poll until `pid` has exited; false if it is still alive at `timeout`.
    static func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// Whether a PID is alive. `kill(pid, 0)` is used because it is the only
    /// check that's reliable for processes LaunchServices doesn't track. It
    /// also succeeds for a zombie — a process that has exited and is only
    /// waiting for its parent to collect it — which counts as dead here.
    static func isAlive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return true }
        return info.kp_proc.p_stat != SZOMB
    }

    /// True while either the app or the helper process is alive.
    static func isRunning(_ app: NSRunningApplication, helperPid: Int32?) -> Bool {
        let appRunning = isAlive(app.processIdentifier)
        let helperRunning = helperPid.map { isAlive($0) } ?? false
        logger.debug("isRunning: app PID \(app.processIdentifier)=\(appRunning), helper PID \(helperPid ?? -1)=\(helperRunning)")
        return appRunning || helperRunning
    }

    /// How long a force-quit app gets to clean up before SIGKILL. A wrapp
    /// stops its Steam and Wine on the way out, and gives itself 15 s.
    static let forceQuitGrace: TimeInterval = 20

    /// Force-terminate the app, then run each cleanup command (see
    /// `ProcessCleanup.install`) to catch helper processes that outlive it.
    static func forceQuit(_ app: NSRunningApplication, cleanupCommands: [[String]] = []) {
        logger.warning("⚠️  Force quitting \(app.localizedName ?? "app")...")
        // forceTerminate doesn't always end the process (a wrapp once outlived
        // it by an hour), so check, and kill it outright if it is still there.
        let pid = app.processIdentifier
        app.forceTerminate()
        if !waitForExit(pid, timeout: forceQuitGrace) {
            logger.warning("⚠️  PID \(pid) survived forceTerminate — sending SIGKILL")
            kill(pid, SIGKILL)
            if !waitForExit(pid, timeout: 3) {
                logger.error("❌ PID \(pid) is still running after SIGKILL")
            }
        }

        for argv in cleanupCommands {
            guard let path = argv.first else { continue }
            let command = Process()
            command.executableURL = URL(fileURLWithPath: path)
            command.arguments = Array(argv.dropFirst())
            do {
                try command.run()
                command.waitUntilExit()
            } catch {
                logger.warning("⚠️  \(argv.joined(separator: " ")) failed: \(error)")
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
