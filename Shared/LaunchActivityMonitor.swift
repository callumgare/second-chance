//
//  LaunchActivityMonitor.swift
//  Shared
//
//  Watches a game's launch for signs it's still getting somewhere, for the
//  wrapp's loading window: a launch that is merely slow keeps showing them,
//  and one that is stuck stops. docs/wrapp-launch.md
//  has what the experiments behind it found.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.LaunchActivity")

/// Samples the launch once a second while the loading window waits, and
/// hears about each sign it sees (`LaunchProgressSign`): Wine's programs (or
/// ScummVM) using the CPU, a Wine program starting, a line of output, Steam
/// writing to its logs. The window's `LoadingClock` decides what they mean.
///
/// Costs one `ps` a second, and only until the game's window appears.
nonisolated final class LaunchActivityMonitor: @unchecked Sendable {
    /// CPU, in cores (core-seconds per second, between two samples), that
    /// Wine's programs must use to count as working. Wine's services idle at
    /// almost nothing; a program getting anywhere uses far more.
    static let busyCores = 0.05

    /// User-initiated, as the player is waiting on what it watches: at a
    /// lower QoS a busy Mac starved it, and its `ps`, to a sample every few
    /// seconds just when the launch needed watching most.
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.Shared.LaunchActivityMonitor", qos: .userInitiated)
    private let steamLogsDir: URL?
    private var onSign: (@Sendable (LaunchProgressSign) -> Void)?
    private var timer: DispatchSourceTimer?
    private var previous: (snapshot: Snapshot, at: Date)?
    private var steamLogBytes: UInt64?
    private let outputLock = NSLock()
    private var sawOutput = false
    private var started = Date()

    /// `steamLogsDir`, Steam's logs, when the game needs Steam running.
    init(steamLogsDir: URL? = nil) {
        self.steamLogsDir = steamLogsDir
    }

    /// Start sampling, telling `onSign` on the main queue about each sign.
    func start(onSign: @escaping @Sendable (LaunchProgressSign) -> Void) {
        queue.async {
            self.onSign = onSign
            guard self.timer == nil else { return }
            self.started = Date()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { self.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.onSign = nil
        }
    }

    /// Wine, Steam or the game printed a line. Cheap: called for every line,
    /// and passed on at the next sample.
    func noteOutput() {
        outputLock.withLock { sawOutput = true }
    }

    private func sample() {
        var signs: [LaunchProgressSign] = []
        var cores: Double?
        if let output = Self.psOutput() {
            let snapshot = Snapshot(psOutput: output)
            let now = Date()
            if let previous {
                // As a rate: on a busy Mac the samples come further apart.
                let interval = max(0.5, now.timeIntervalSince(previous.at))
                let rate = snapshot.cpuUsed(since: previous.snapshot) / interval
                let steamRate = snapshot.cpuUsed(since: previous.snapshot, steam: true) / interval
                cores = rate
                if rate >= Self.busyCores { signs.append(.cpu) }
                if steamRate >= Self.busyCores { signs.append(.steamCPU) }
                for name in snapshot.names.subtracting(previous.snapshot.names).sorted() {
                    signs.append(.newProcess(name))
                }
            }
            previous = (snapshot, now)
        }
        if outputLock.withLock({ defer { sawOutput = false }; return sawOutput }) {
            signs.append(.output)
        }
        if let steamLogsDir {
            let bytes = Self.bytes(in: steamLogsDir)
            if let before = steamLogBytes, bytes > before { signs.append(.steamLog) }
            steamLogBytes = bytes
        }
        // A line a second while the game loads, for working out afterwards
        // what a slow or stuck launch was doing.
        let elapsed = String(format: "%.0f", Date().timeIntervalSince(started))
        let used = cores.map { String(format: "%.2f cores", $0) } ?? "?"
        let shown = signs.map { sign -> String in
            switch sign {
            case .cpu: return "cpu"
            case .steamCPU: return "steam-cpu"
            case .steamLaunchStep: return "steam-step"
            case .newProcess(let name): return "+\(name)"
            case .output: return "output"
            case .steamLog: return "steam-log"
            }
        }
        logger.debug("[Launch] \(elapsed)s: Wine CPU \(used); \(shown.isEmpty ? "no progress" : shown.joined(separator: " "))")
        guard !signs.isEmpty, let onSign else { return }
        DispatchQueue.main.async {
            for sign in signs { onSign(sign) }
        }
    }

    /// The Wine programs (and ScummVM) running at one moment, with the CPU
    /// time each has used so far. Leaves out what the wrapp runs itself to
    /// check on the launch, which says nothing about it: Wine's desktop is
    /// checked for with `reg.exe`, a Wine program of its own each time, and
    /// the server's CPU is mostly its work for those.
    struct Snapshot: Equatable {
        static let ignored: Set<String> = ["reg.exe", "conhost.exe", "wineserver", "wine", "wine64", "wine-preloader"]
        /// Steam's own programs, whose CPU says little: they use it idle.
        static let steam: Set<String> = ["steam.exe", "steamwebhelper.exe", "steamservice.exe", "gameoverlayui.exe",
                                         "gameoverlayui64.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe"]

        /// CPU seconds by pid.
        let cpu: [Int32: Double]
        /// Which of those pids are Steam's own programs.
        let steamPids: Set<Int32>
        /// Their executables' names, lowercased: "explorer.exe", "game.exe".
        let names: Set<String>

        /// From `ps -A -o pid=,time=,comm=`.
        init(psOutput: String) {
            var cpu: [Int32: Double] = [:]
            var steamPids: Set<Int32> = []
            var names: Set<String> = []
            for line in psOutput.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count == 3, let pid = Int32(fields[0]),
                      let seconds = Self.seconds(fromPSTime: String(fields[1])) else { continue }
                let command = String(fields[2])
                let name = ProcessName.executable(fromPSCommand: command).lowercased()
                guard SystemLoad.isWine(command: command) || name == "scummvm", !Self.ignored.contains(name) else { continue }
                cpu[pid] = seconds
                if Self.steam.contains(name) { steamPids.insert(pid) }
                names.insert(name)
            }
            self.cpu = cpu
            self.steamPids = steamPids
            self.names = names
        }

        /// CPU seconds used since `previous`: by the programs in both, the
        /// difference, and by new ones, all they've used. Steam's own
        /// programs' when `steam`, and everything else's otherwise.
        func cpuUsed(since previous: Snapshot, steam: Bool = false) -> Double {
            cpu.reduce(0) { total, entry in
                guard steamPids.contains(entry.key) == steam else { return total }
                return total + max(0, entry.value - (previous.cpu[entry.key] ?? 0))
            }
        }

        /// `ps`'s `time`: "[[dd-]hh:]mm:ss.cc".
        static func seconds(fromPSTime text: String) -> Double? {
            var rest = Substring(text)
            var days = 0.0
            if let dash = rest.firstIndex(of: "-") {
                guard let value = Double(rest[..<dash]) else { return nil }
                days = value
                rest = rest[rest.index(after: dash)...]
            }
            var seconds = 0.0
            for part in rest.split(separator: ":") {
                guard let value = Double(part) else { return nil }
                seconds = seconds * 60 + value
            }
            return days * 86_400 + seconds
        }
    }

    private static func psOutput() -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,time=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return nil
        }
        // Read before waiting: the list can be bigger than the pipe's buffer.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return output
    }

    private static func bytes(in directory: URL) -> UInt64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, file in
            total + UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
