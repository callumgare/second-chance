//
//  StartupDiagnostics.swift
//  WrappTemplate
//
//  Captures a diagnostics bundle when a Wine game starts badly — no window
//  after a few seconds, a crash, or a hang — so an intermittent failure leaves
//  evidence behind instead of only a log line.
//
//  The motivating case: Secrets Can Kill Remastered sometimes stalls while
//  Wine's Mac driver initialises, and if Direct3D isn't up ~10s in, the game
//  crashes on a null pointer. Whatever stalls it happens outside the game's own
//  output, so the bundle samples the process's native thread stacks and records
//  what the rest of the machine was doing at the time.
//
//  Costs nothing on a normal launch: the only work before a trigger is a timer
//  and a ring buffer of recent Wine output lines.
//
//  Bundles land in ~/Library/Logs/SecondChance/diagnostics/<slug>-<time>-<reason>/
//  and the newest `maxBundles` are kept. SECOND_CHANCE_DIAGNOSTICS=0 turns this
//  off; SECOND_CHANCE_DIAG_SLOW_SECONDS changes the slow-start threshold.
//

import Foundation
import Logging

/// `@unchecked Sendable`: every piece of mutable state is confined to `queue`.
final class StartupDiagnostics: @unchecked Sendable {

    enum Reason: String {
        /// The game process is up but has no window after `slowSeconds`.
        case slowStart = "slow-start"
        /// Wine reported an unhandled exception in the game.
        case crash
        /// Still no window after `hangSeconds`.
        case hang
        /// The game exited without ever showing a window.
        case exitedBeforeWindow = "exited-before-window"
    }

    private let gameSlug: String
    private let gameTitle: String
    private let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Diagnostics")
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.WrappTemplate.Diagnostics")

    private let enabled: Bool
    private let slowSeconds: Double
    private let hangSeconds: Double = 25
    private let maxBundles = 10
    private let recentLineLimit = 300

    // State below is only touched on `queue`.
    private var launchTime = Date()
    private var gamePid: Int32?
    private var gameStartTime: Date?
    private var windowAppeared = false
    private var captured: Set<Reason> = []
    private var recentLines: [String] = []
    private var timers: [DispatchWorkItem] = []

    init(gameSlug: String, gameTitle: String) {
        self.gameSlug = gameSlug
        self.gameTitle = gameTitle
        let env = ProcessInfo.processInfo.environment
        enabled = env["SECOND_CHANCE_DIAGNOSTICS"] != "0"
        slowSeconds = env["SECOND_CHANCE_DIAG_SLOW_SECONDS"].flatMap(Double.init) ?? 8
    }

    // MARK: - Events from the launcher

    /// Call when the Wine process is launched, before the game exe appears.
    func wineLaunched() {
        queue.async { self.launchTime = Date() }
    }

    /// Feed every line of Wine's stdout/stderr. Keeps a ring buffer for the
    /// bundle and triggers a crash capture on Wine's unhandled-exception line.
    func observe(line: String) {
        guard enabled else { return }
        queue.async {
            self.recentLines.append("\(Self.timestamp(Date())) \(line)")
            if self.recentLines.count > self.recentLineLimit {
                self.recentLines.removeFirst(self.recentLines.count - self.recentLineLimit)
            }
            if line.contains("Unhandled page fault")
                || line.contains("Unhandled exception")
                || line.contains("Unhandled stack overflow") {
                self.capture(.crash)
            }
        }
    }

    /// Call once the game's own process (not the wine launcher) is found.
    func gameStarted(pid: Int32) {
        guard enabled else { return }
        queue.async {
            self.gamePid = pid
            self.gameStartTime = Date()
            for (delay, reason) in [(self.slowSeconds, Reason.slowStart), (self.hangSeconds, Reason.hang)] {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, !self.windowAppeared else { return }
                    self.capture(reason)
                }
                self.timers.append(item)
                self.queue.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }
    }

    /// Call when the game's first window is detected.
    func gameWindowAppeared() {
        queue.async {
            self.windowAppeared = true
            self.timers.forEach { $0.cancel() }
            self.timers.removeAll()
        }
    }

    /// Call when the game has exited.
    func gameExited(exitCode: Int32) {
        guard enabled else { return }
        queue.async {
            self.timers.forEach { $0.cancel() }
            self.timers.removeAll()
            if !self.windowAppeared && self.gameStartTime != nil {
                self.recentLines.append("\(Self.timestamp(Date())) [diagnostics] game exited with code \(exitCode)")
                self.capture(.exitedBeforeWindow)
            }
        }
    }

    // MARK: - Capture

    /// Runs on `queue`. Each reason is captured at most once per launch.
    private func capture(_ reason: Reason) {
        guard !captured.contains(reason) else { return }
        captured.insert(reason)

        let now = Date()
        let dir: URL
        do {
            dir = try makeBundleDirectory(reason: reason, at: now)
        } catch {
            logger.warning("[Diagnostics] could not create bundle directory: \(error)")
            return
        }
        let sinceStart = gameStartTime.map { String(format: "%.1fs", now.timeIntervalSince($0)) } ?? "n/a"
        logger.error("[Diagnostics] \(reason.rawValue) (\(sinceStart) after game start) — capturing to \(dir.path)")

        // Snapshot the shared state now; the slow commands below don't touch it.
        let pid = gamePid
        let lines = recentLines
        let summary = """
            reason: \(reason.rawValue)
            game: \(gameTitle) (\(gameSlug))
            captured: \(Self.timestamp(now))
            wine launched: \(Self.timestamp(launchTime))
            game started: \(gameStartTime.map(Self.timestamp) ?? "not detected")
            since game start: \(sinceStart)
            game pid: \(pid.map(String.init) ?? "unknown")
            window appeared: \(windowAppeared)
            wrapp version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            WINEDEBUG: \(ProcessInfo.processInfo.environment["SECOND_CHANCE_WINEDEBUG"].flatMap { $0.isEmpty ? nil : $0 } ?? WineEnvironment.defaultWineDebug)

            Files: sample.txt (thread stacks of the game process), sample-<name>-<pid>.txt
            (every other Wine process, sampled at the same moment), top.txt (CPU/memory),
            processes.txt, session.txt (display/lock/screen-sharing), log.txt (system
            log for the game process), wine-output.txt (last \(recentLineLimit) Wine lines).

            """
        write(summary, to: dir.appendingPathComponent("summary.txt"))
        write(lines.joined(separator: "\n") + "\n", to: dir.appendingPathComponent("wine-output.txt"))

        // The slow part runs off `queue` so later lines and triggers still get in.
        DispatchQueue.global(qos: .utility).async {
            // The process list first: sampling takes seconds once symbolication
            // is counted, long enough for a crashing game to be gone by the end.
            let processList = self.runToString("/bin/ps", ["-A", "-o", "pid,ppid,pcpu,pmem,etime,comm"], timeout: 10)
            self.write(processList, to: dir.appendingPathComponent("processes.txt"))

            // Then top and the samples, all at once. Every Wine process is
            // sampled, not just the game: a stalled game is often waiting on
            // another one (explorer.exe, a child it launched, wineserver).
            var targets: [(pid: Int32, file: String)] = []
            if let pid { targets.append((pid, "sample.txt")) }
            for process in Self.wineProcesses(in: processList) where process.pid != pid {
                targets.append((process.pid, "sample-\(process.name)-\(process.pid).txt"))
            }
            let group = DispatchGroup()
            for target in targets {
                DispatchQueue.global(qos: .utility).async(group: group) {
                    self.run("/usr/bin/sample", [String(target.pid), "2", "-mayDie", "-file", dir.appendingPathComponent(target.file).path],
                             timeout: 30, into: dir.appendingPathComponent("sample-stdout-\(target.pid).txt"))
                }
            }
            DispatchQueue.global(qos: .utility).async(group: group) {
                self.run("/usr/bin/top", ["-l", "2", "-s", "1", "-o", "cpu", "-n", "25", "-stats", "pid,command,cpu,mem,state"],
                         timeout: 15, into: dir.appendingPathComponent("top.txt"))
            }
            group.wait()

            self.captureSession(into: dir.appendingPathComponent("session.txt"))
            if let pid {
                self.run("/usr/bin/log", ["show", "--last", "60s", "--style", "compact", "--predicate", "processIdentifier == \(pid)"],
                         timeout: 45, into: dir.appendingPathComponent("log.txt"))
            }
            self.logger.error("[Diagnostics] \(reason.rawValue) bundle complete: \(dir.path)")
        }
    }

    private func captureSession(into file: URL) {
        var text = ""
        text += "== load average\n" + runToString("/usr/sbin/sysctl", ["-n", "vm.loadavg"], timeout: 5)
        text += "\n== memory pressure\n" + runToString("/usr/bin/memory_pressure", ["-Q"], timeout: 10)
        text += "\n== thermal\n" + runToString("/usr/bin/pmset", ["-g", "therm"], timeout: 5)
        let ioreg = runToString("/usr/sbin/ioreg", ["-n", "Root", "-d1", "-a"], timeout: 5)
        text += "\n== screen locked: \(ioreg.contains("<key>CGSSessionScreenIsLocked</key>"))\n"
        let screenSharing = runToString("/usr/bin/pgrep", ["-x", "screensharingd"], timeout: 5)
        text += "== screen sharing active: \(!screenSharing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)\n"
        text += "\n== displays\n" + runToString("/usr/sbin/system_profiler", ["SPDisplaysDataType"], timeout: 20)
        write(text, to: file)
    }

    // MARK: - Helpers

    /// Windows processes (`*.exe`) and `wineserver` from a
    /// `ps -o pid,ppid,pcpu,pmem,etime,comm` listing. The comm column is a path
    /// and may contain spaces, so only the first five fields are split off.
    static func wineProcesses(in processList: String) -> [(pid: Int32, name: String)] {
        processList.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int32(fields[0]) else { return nil }
            let name = (String(fields[5]) as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".exe") || name == "wineserver" else { return nil }
            let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            return (pid, safeName)
        }
    }

    private func makeBundleDirectory(reason: Reason, at date: Date) throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SecondChance/diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        prune(base)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = base.appendingPathComponent("\(gameSlug)-\(formatter.string(from: date))-\(reason.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Keep the newest `maxBundles - 1`, making room for the one about to be written.
    private func prune(_ base: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = entries.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(maxBundles - 1) {
            do {
                try fm.removeItem(at: old)
            } catch {
                logger.warning("[Diagnostics] could not prune \(old.lastPathComponent): \(error)")
            }
        }
    }

    private func write(_ text: String, to file: URL) {
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("[Diagnostics] could not write \(file.lastPathComponent): \(error)")
        }
    }

    private func run(_ path: String, _ args: [String], timeout: TimeInterval, into file: URL) {
        write(runToString(path, args, timeout: timeout), to: file)
    }

    /// Runs a command, killing it after `timeout`; returns stdout+stderr.
    private func runToString(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return "failed to run \(path): \(error)\n"
        }
        // Drain while it runs so a large output can't fill the pipe and block it.
        var output = Data()
        let reader = DispatchQueue(label: "au.gare.callum.second-chance.WrappTemplate.Diagnostics.reader")
        reader.async { output = pipe.fileHandleForReading.readDataToEndOfFile() }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            reader.sync {}
            return String(decoding: output, as: UTF8.self) + "\n[timed out after \(Int(timeout))s]\n"
        }
        reader.sync {}
        return String(decoding: output, as: UTF8.self)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
