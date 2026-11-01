//
//  ProcessControl.swift
//  WrappPuppeteer
//
//  Launching, finding, waiting on and killing the processes under test.

import Foundation
import AppKit
import Logging
import SecondChanceKit

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

/// A process `ProcessFinder` found: its pid, executable `name` and
/// `command` as `ps` reports it.
typealias RunningProcess = ProcessList.Entry

enum ProcessFinder {
    /// Every process on the system, via `ps`. Sees processes that
    /// NSWorkspace doesn't, such as Wine's.
    static func allProcesses() -> [RunningProcess] {
        guard let processes = ProcessList.current() else {
            logger.error("  ⚠️  Couldn't list processes")
            return []
        }
        return processes.entries
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

    /// Open an app that is already running, as clicking its Dock icon does:
    /// LaunchServices sends it a reopen and makes it active. Whether
    /// LaunchServices took the request.
    @discardableResult
    static func reopen(appPath: String) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        var opened = false
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: configuration) { runningApp, error in
            if let error {
                logger.warning("⚠️  Couldn't reopen \(appPath): \(error.localizedDescription)")
            }
            opened = runningApp != nil
            semaphore.signal()
        }
        semaphore.wait()
        return opened
    }

    private static var finishedLaunching = false

    /// Take the screen from the app in front, as Cmd-Tab to another app
    /// does: become a regular app with a window, then have the app in front
    /// hand this one activation (`handOver`; since macOS 14 an app can't take
    /// it otherwise) and take it. macOS can't show a regular app's window in
    /// another app's fullscreen Space, so it slides over to the desktop's.
    /// Waits until the window is on screen. Returns the window, for
    /// `giveBackScreen`, or nil if it never showed (and then gives the
    /// screen back itself).
    static func takeOverScreen(title: String, timeout: TimeInterval = 15, handOver: () -> Bool) -> NSWindow? {
        if !finishedLaunching {
            NSApp.finishLaunching()
            finishedLaunching = true
        }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        handleEvents(for: 0.2)
        guard handOver() else {
            logger.warning("⚠️  The app in front didn't hand over activation")
            giveBackScreen(window)
            return nil
        }
        NSApp.activate()
        let deadline = Date().addingTimeInterval(timeout)
        while !window.occlusionState.contains(.visible), Date() < deadline {
            handleEvents(for: 0.1)
        }
        guard window.occlusionState.contains(.visible) else {
            logger.warning("⚠️  WrappPuppeteer's window never came on screen within \(Int(timeout))s")
            giveBackScreen(window)
            return nil
        }
        return window
    }

    /// Take the screen from the app in front and give it straight back to
    /// `pid`, as a quick tap of Cmd-Tab does: become a regular app with a
    /// window, have the app in front hand over activation (`handOver`), and
    /// as soon as this app is active, hand activation back and activate
    /// `pid`'s app, without waiting for anything to have moved. False if
    /// this app never became active within `timeout`.
    static func takeScreenBriefly(title: String, handBackTo pid: pid_t, timeout: TimeInterval = 15, handOver: () -> Bool) -> Bool {
        if !finishedLaunching {
            NSApp.finishLaunching()
            finishedLaunching = true
        }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        handleEvents(for: 0.2)
        defer { giveBackScreen(window) }
        guard handOver() else {
            logger.warning("⚠️  The app in front didn't hand over activation")
            return false
        }
        NSApp.activate()
        let deadline = Date().addingTimeInterval(timeout)
        while !NSApp.isActive, Date() < deadline {
            handleEvents(for: 0.01)
        }
        guard NSApp.isActive, let app = NSRunningApplication(processIdentifier: pid) else {
            logger.warning("⚠️  WrappPuppeteer never became active within \(Int(timeout))s")
            return false
        }
        NSApp.yieldActivation(to: app)
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// Close the window `takeOverScreen` showed, and go back to being an
    /// accessory app, whose windows (the click ring) can show over another
    /// app's fullscreen Space.
    static func giveBackScreen(_ window: NSWindow?) {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
        handleEvents(for: 0.1)
    }

    /// Take AppKit's events off the queue and handle them for `seconds`.
    /// WrappPuppeteer never runs NSApp's event loop, and becoming active or
    /// a window coming on screen arrives as events: left on the queue,
    /// neither happens.
    static func handleEvents(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
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

    /// How long a force-quit app gets to clean up before SIGKILL.
    /// `forceTerminate` sends SIGTERM, which a wrapp takes as Cmd-Q: it ends
    /// its game, waits for Wine to finish, and kills it itself after 15 s.
    static let forceQuitGrace: TimeInterval = 20

    /// Force-terminate the app (SIGTERM), SIGKILL it only if it is still
    /// running `forceQuitGrace` later, then run `cleanup`, for helper
    /// processes that can outlive it.
    static func forceQuit(_ app: NSRunningApplication, cleanup: () -> Void = {}) {
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
        cleanup()
    }

    /// Whether any process's command line matches `pattern` (`pgrep -f`).
    static func anyRunning(matching pattern: String) -> Bool {
        run("/usr/bin/pgrep", ["-f", "--", pattern]) == 0
    }

    /// Signal every process whose command line matches `pattern`
    /// (`pkill -f`), and wait up to `timeout` for them all to go. Whether
    /// they did.
    static func end(matching pattern: String, signal: Int32, timeout: TimeInterval) -> Bool {
        _ = run("/usr/bin/pkill", ["-\(signal)", "-f", "--", pattern])
        let deadline = Date().addingTimeInterval(timeout)
        while anyRunning(matching: pattern) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    /// Run a program and return its exit status, or -1 if it couldn't start.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: path)
        command.arguments = arguments
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        do {
            try command.run()
        } catch {
            logger.warning("⚠️  \(([path] + arguments).joined(separator: " ")) failed: \(error)")
            return -1
        }
        command.waitUntilExit()
        return command.terminationStatus
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
