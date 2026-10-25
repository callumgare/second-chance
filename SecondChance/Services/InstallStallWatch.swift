//
//  InstallStallWatch.swift
//  SecondChance
//
//  Notices an unattended install that has stopped getting anywhere, so the
//  build can say so and hand the person the installer's own wizard, rather
//  than show progress for the half hour until the install's timeout.
//  docs/wrapp-build.md#a-stalled-install has the numbers behind the window.
//

import AppKit
import CoreGraphics
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.InstallStallWatch")

/// When a quiet install counts as stalled.
nonisolated struct InstallStallRule: Equatable {
    /// How long an install may go without a sign of progress, on a Mac that
    /// isn't heavily loaded.
    let window: TimeInterval

    /// `SECOND_CHANCE_INSTALL_STALL_SECONDS` seconds, default 120; 0 turns
    /// the watch off.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> InstallStallRule? {
        let seconds = env["SECOND_CHANCE_INSTALL_STALL_SECONDS"].flatMap(TimeInterval.init) ?? defaultWindow
        return seconds > 0 ? InstallStallRule(window: seconds) : nil
    }

    static let defaultWindow: TimeInterval = 120

    /// Three times as long while the Mac is heavily loaded, as for a wrapp's
    /// launch (`LoadingStage.heavyLoadFactor`): Wine's programs then go
    /// quiet for longer between bursts.
    func limit(heavyLoad: Bool) -> TimeInterval {
        heavyLoad ? window * LoadingStage.heavyLoadFactor : window
    }

    func isStalled(quietFor: TimeInterval, heavyLoad: Bool) -> Bool {
        quietFor >= limit(heavyLoad: heavyLoad)
    }

    /// The signs that an install is still getting somewhere: Wine's programs
    /// using the CPU, a new one starting, or a line of output.
    static func isProgress(_ sign: LaunchProgressSign) -> Bool {
        switch sign {
        case .cpu, .newProcess, .output: true
        case .steamCPU, .steamLaunchStep, .steamLog: false
        }
    }
}

/// Watches one unattended installer run, through `LaunchActivityMonitor`'s
/// signs, the installer's own log, and the folders it writes to, and answers
/// `runWine`'s checks. The folders matter: under load an Inno Setup install
/// copied the game for minutes at 0.02 cores, below what counts as Wine
/// working, saying nothing on its output. Quiet for longer than the rule
/// allows, it looks for a window the installer has put on screen: if there
/// is one, the installer is asking something, so the person is told and the
/// timeout waits; if not, the install has stalled.
nonisolated final class InstallStallWatch: WineWatchdog, @unchecked Sendable {
    private let rule: InstallStallRule
    private let monitor = LaunchActivityMonitor()
    private let lock = NSLock()
    private var lastProgress = Date()
    private var longestQuiet: TimeInterval = 0
    private var waitingOnPerson = false
    /// Where the install writes; a change in their size or file count is
    /// progress.
    private let folders: [URL]
    private var lastSize: [DirectorySize] = []
    /// Told when the installer starts or stops waiting on the person.
    private let onWaitingOnPerson: @Sendable (Bool) -> Void

    /// `driveC`, the prefix's `drive_c`: the watch looks at its
    /// `Program Files (x86)` and `users` (where Temp is).
    init(rule: InstallStallRule, driveC: URL, onWaitingOnPerson: @escaping @Sendable (Bool) -> Void) {
        self.rule = rule
        self.folders = ["Program Files (x86)", "users"].map { driveC.appendingPathComponent($0, isDirectory: true) }
        self.onWaitingOnPerson = onWaitingOnPerson
    }

    func start() {
        let sizes = measureFolders()
        lock.withLock {
            lastProgress = Date()
            lastSize = sizes
        }
        monitor.start { [weak self] sign in
            guard InstallStallRule.isProgress(sign) else { return }
            self?.sawProgress()
        }
    }

    /// Stop watching, and log the longest the install went without a sign of
    /// progress — the numbers the window is set from.
    func stop() {
        monitor.stop()
        let longest = lock.withLock { max(longestQuiet, Date().timeIntervalSince(lastProgress)) }
        logger.notice("[Install] longest quiet: \(Int(longest))s (stalls after \(Int(rule.window))s, or \(Int(rule.limit(heavyLoad: true)))s heavily loaded)")
    }

    /// A line from Wine, or from the installer's own log.
    func sawOutput() {
        monitor.noteOutput()
    }

    func check() -> WineWatchdogVerdict {
        let sizes = measureFolders()
        if lock.withLock({ defer { lastSize = sizes }; return sizes != lastSize }) {
            sawProgress()
        }
        let quietFor = lock.withLock { Date().timeIntervalSince(lastProgress) }
        guard quietFor >= rule.window else { return .carryOn }
        let heavyLoad = SystemLoad.read()?.isHeavy ?? false
        guard rule.isStalled(quietFor: quietFor, heavyLoad: heavyLoad) else { return .carryOn }

        if let window = Self.installerWindowOnScreen() {
            if lock.withLock({ defer { waitingOnPerson = true }; return !waitingOnPerson }) {
                logger.notice("[Install] Quiet for \(Int(quietFor))s with \(window.owner)'s window on screen: waiting on the person")
                NSRunningApplication(processIdentifier: window.pid)?.activate()
                onWaitingOnPerson(true)
            }
            return .waitingOnPerson
        }
        logger.warning("[Install] No sign of progress for \(Int(quietFor))s\(heavyLoad ? " (heavily loaded)" : ""), and no installer window on screen: stalled")
        return .stalled(quietFor: quietFor)
    }

    private func sawProgress() {
        let wasWaiting = lock.withLock {
            longestQuiet = max(longestQuiet, Date().timeIntervalSince(lastProgress))
            lastProgress = Date()
            defer { waitingOnPerson = false }
            return waitingOnPerson
        }
        if wasWaiting {
            logger.notice("[Install] Progress again: no longer waiting on the person")
            onWaitingOnPerson(false)
        }
    }

    private func measureFolders() -> [DirectorySize] {
        folders.map { DirectorySize.measure($0) }
    }

    // MARK: - The installer's window

    /// A window a Wine program has on screen, if any. Wine's own hidden
    /// windows (the desktop's, a program's 500×500 placeholder) are never on
    /// screen, so any that is belongs to the installer or one it started.
    static func installerWindowOnScreen() -> (pid: pid_t, owner: String)? {
        let winePids = wineProcessIDs()
        guard !winePids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return onScreenWindowOwner(in: windows, winePids: winePids)
    }

    /// The first window in `windows` (from `CGWindowListCopyWindowInfo`) that
    /// a Wine program owns and that is big enough to be something to answer.
    static func onScreenWindowOwner(in windows: [[String: Any]], winePids: Set<pid_t>) -> (pid: pid_t, owner: String)? {
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, winePids.contains(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50 else { continue }
            return (pid, window[kCGWindowOwnerName as String] as? String ?? "a Wine program")
        }
        return nil
    }

    private static func wineProcessIDs() -> Set<pid_t> {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            logger.warning("[Install] Couldn't list processes to look for the installer's window: \(error)")
            return []
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        var pids: Set<pid_t> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = pid_t(fields[0]), SystemLoad.isWine(command: String(fields[1])) else { continue }
            pids.insert(pid)
        }
        return pids
    }
}
