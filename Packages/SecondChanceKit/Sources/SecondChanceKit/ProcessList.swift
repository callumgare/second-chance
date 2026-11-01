//
//  ProcessList.swift
//  SecondChanceKit
//
//  Every process running at one moment, as `ps` lists it.

import Foundation

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

        public init(pid: pid_t, parent: pid_t = 1, cpuPercent: Double = 0, cpuSeconds: Double = 0,
                    elapsedSeconds: Double = 0, command: String) {
            self.pid = pid
            self.parent = parent
            self.cpuPercent = cpuPercent
            self.cpuSeconds = cpuSeconds
            self.elapsedSeconds = elapsedSeconds
            self.command = command
        }

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
    public static func current() -> ProcessList? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,pcpu=,time=,etime=,comm="]
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
        return ProcessList(psOutput: output)
    }

    /// From `ps -A -o pid=,ppid=,pcpu=,time=,etime=,comm=`. The command is
    /// last because it can hold spaces.
    init(psOutput: String) {
        self.init(entries: psOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]),
                  let cpuPercent = Double(fields[2]), let cpuSeconds = Self.seconds(fromPSTime: String(fields[3])),
                  let elapsedSeconds = Self.seconds(fromPSTime: String(fields[4])) else { return nil }
            return Entry(pid: pid, parent: parent, cpuPercent: cpuPercent, cpuSeconds: cpuSeconds,
                         elapsedSeconds: elapsedSeconds, command: String(fields[5]))
        })
    }

    /// Wine's processes, the game among them.
    public var wine: [Entry] { entries.filter(\.isWine) }

    /// The processes whose executable is `name`, compared without case.
    public func named(_ name: String) -> [Entry] {
        let wanted = name.lowercased()
        return entries.filter { $0.name.lowercased() == wanted }
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
