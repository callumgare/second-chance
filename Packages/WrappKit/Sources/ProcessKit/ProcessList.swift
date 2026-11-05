//
//  ProcessList.swift
//  ProcessKit
//
//  Every process running at one moment, as `ps` lists it.

import Darwin
import Foundation
import Synchronization
import WrappLogging

/// Every process running at one moment, as `ps` lists it: where Second
/// Chance, the wrapp and WrappPuppeteer ask what is running, and the one
/// place that says which processes are Wine's.
nonisolated public struct ProcessList: Sendable {
    nonisolated public struct Entry: Sendable, Hashable {
        public let pid: pid_t
        public let parent: pid_t
        /// Recent CPU use, as `ps`'s `pcpu`: 100 is one core.
        public let cpuPercent: Double
        /// CPU time used so far, in seconds.
        public let cpuSeconds: Double
        /// How long it has been running, in seconds.
        public let elapsedSeconds: Double
        /// `ps`'s `comm`: the executable's path, or for a Windows program
        /// under Wine 10, its Windows path (`ProcessName`).
        public let command: String
        /// The user it runs as; nil when the listing didn't say, which counts
        /// as this process's user.
        public let uid: uid_t?

        public init(pid: pid_t, parent: pid_t = 1, cpuPercent: Double = 0, cpuSeconds: Double = 0,
                    elapsedSeconds: Double = 0, command: String, uid: uid_t? = nil) {
            self.pid = pid
            self.parent = parent
            self.cpuPercent = cpuPercent
            self.cpuSeconds = cpuSeconds
            self.elapsedSeconds = elapsedSeconds
            self.command = command
            self.uid = uid
        }

        /// Whether it runs as the same user as this process. A Mac can have
        /// several users logged in at once (a test user in the background, say),
        /// each running games of their own: those are never this process's
        /// game, its Wine, or a sign its launch is progressing.
        public var isMine: Bool { uid.map { $0 == getuid() } ?? true }

        /// The executable's file name: "Game.exe", "wineserver".
        public var name: String { ProcessName.executable(fromPSCommand: command) }

        /// Whether it is one of Wine's (`ProcessList.isWine`).
        public var isWine: Bool { ProcessList.isWine(command: command) }
    }

    public let entries: [Entry]
    /// Each process's parent, by pid.
    private let parents: [pid_t: pid_t]

    public init(entries: [Entry]) {
        self.entries = entries
        parents = Dictionary(entries.map { ($0.pid, $0.parent) }) { first, _ in first }
    }

    /// What's running now; nil when `ps` couldn't be run. Blocks for as long
    /// as `ps` takes, well under a second.
    /// The last listing taken, and when: what `recent(maxAge:)` reuses.
    private static let latest = Mutex<(list: ProcessList, at: ContinuousClock.Instant)?>(nil)

    /// A listing no older than `maxAge`: the last one taken, if it's new
    /// enough, else a fresh one. For what samples every few seconds (the
    /// load, the game's process tree, an install's stall watch): while a
    /// launch's activity monitor lists every second, they share its
    /// listings rather than each running `ps` on a Mac that is often busy.
    public static func recent(maxAge: Duration) -> ProcessList? {
        if let latest = latest.withLock({ $0 }), ContinuousClock.now - latest.at <= maxAge {
            return latest.list
        }
        return current()
    }

    /// A fresh listing, from `ps`.
    public static func current() -> ProcessList? {
        let taken = ContinuousClock.now
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,uid=,pcpu=,time=,etime=,comm="]
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
        let list = ProcessList(psOutput: output)
        latest.withLock { $0 = (list, taken) }
        return list
    }

    /// From `ps -A -o pid=,ppid=,uid=,pcpu=,time=,etime=,comm=`. The command
    /// is last because it can hold spaces. A line without the `uid` column
    /// (`pid=,ppid=,pcpu=,…`) is read too, as this user's.
    init(psOutput: String) {
        self.init(entries: psOutput.split(whereSeparator: \.isNewline).compactMap(Self.entry(fromPSLine:)))
    }

    private static func entry(fromPSLine line: Substring) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        // A uid is a whole number; a CPU percentage, in the same place
        // without one, always has a decimal point.
        let hasUID = fields.count == 7 && uid_t(fields[2]) != nil
        let rest = hasUID ? Array(fields[3...]) : Array(line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).dropFirst(2))
        guard fields.count >= 6, rest.count == 4, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]),
              let cpuPercent = Double(rest[0]), let cpuSeconds = seconds(fromPSTime: String(rest[1])),
              let elapsedSeconds = seconds(fromPSTime: String(rest[2])) else { return nil }
        return Entry(pid: pid, parent: parent, cpuPercent: cpuPercent, cpuSeconds: cpuSeconds,
                     elapsedSeconds: elapsedSeconds, command: String(rest[3]), uid: hasUID ? uid_t(fields[2]) : nil)
    }

    /// Wine's processes, the game among them: this user's only.
    public var wine: [Entry] { entries.filter { $0.isWine && $0.isMine } }

    /// The processes whose executable is `name`, compared without case: this
    /// user's only, so another user's game of the same name is never taken
    /// for ours.
    public func named(_ name: String) -> [Entry] {
        let wanted = name.lowercased()
        return entries.filter { $0.isMine && $0.name.lowercased() == wanted }
    }

    /// Whether `pid` is `ancestor`, or was started by it or by something it
    /// started.
    public func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        var next: pid_t? = pid
        var steps = 0
        while let current = next, current > 1, steps < 64 {
            if current == ancestor { return true }
            next = parents[current]
            steps += 1
        }
        return false
    }

    /// Whether a process named `name` (compared without case: "steam.exe")
    /// is running. True when `ps` can't be run, so a caller waiting for one
    /// to go doesn't give up on a failed check.
    public static func isRunning(_ name: String) -> Bool {
        current().map { !$0.named(name).isEmpty } ?? true
    }

    /// Wine's own processes: the loader and server, and every Windows program
    /// it runs (named by its `.exe`, or from a `winetemp-` directory).
    public static func isWine(command: String) -> Bool {
        ProcessName.executable(fromPSCommand: command).lowercased().hasSuffix(".exe")
            || command.contains("/winetemp-")
            || command.contains("/wine/bin/")
            || command.contains("/wine/lib/")
    }

    /// `ps`'s `time` and `etime`: "[[dd-]hh:]mm:ss[.cc]".
    public static func seconds(fromPSTime text: String) -> Double? {
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

nonisolated extension ProcessList {
    /// The folder `pid` is working in, as the kernel has it (symlinks
    /// resolved); nil when it can't be read: gone, or another user's.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            let path = String(cString: base)
            return path.isEmpty ? nil : path
        }
    }
}
