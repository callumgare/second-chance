//
//  SystemLoad.swift
//  Shared
//
//  How much of the Mac's CPU other programs are using.

import Foundation

/// One reading of how busy the Mac is with work other than our own.
///
/// What starves Wine is other programs taking the performance cores, so that
/// is what this measures: the CPU used by every process except Wine's and the
/// caller's own, in cores, against the Mac's performance-core count. The load
/// average is no use for this — Wine's own threads, starved, push it past 100
/// on a ten-core Mac.
public struct SystemLoadReading: Sendable, Equatable {
    /// Cores' worth of CPU other programs are using (`ps`'s decaying average).
    public let otherCores: Double
    /// Performance cores (all cores on a Mac without performance levels).
    public let fastCores: Int
    /// The programs using the most, by name, with their cores' worth.
    public let topPrograms: [Program]

    public struct Program: Sendable, Equatable {
        public let name: String
        public let cores: Double
    }

    /// With every performance core busy (eight CPU hogs on a Mac with eight)
    /// a fresh Wine session took minutes to bring its desktop up, or never
    /// did; with six it started in seconds. So: heavy once other programs use
    /// all but one performance core.
    public var isHeavy: Bool { otherCores >= Double(max(1, fastCores - 1)) }

    /// "other programs are keeping 7.4 cores busy, and this Mac has 8
    /// performance cores (most: yes, Google Chrome)". Not "7.4 of its 8":
    /// they can be using the efficiency cores too.
    public var summary: String {
        var text = "other programs are keeping \(String(format: "%.1f", otherCores)) cores busy, and this Mac has \(fastCores) performance cores"
        if !topPrograms.isEmpty {
            text += " (most: \(topPrograms.map(\.name).joined(separator: ", ")))"
        }
        return text
    }
}

public enum SystemLoad {
    /// Performance cores, or all physical cores where there are no levels
    /// (Intel Macs).
    public static let fastCoreCount: Int = {
        for name in ["hw.perflevel0.physicalcpu", "hw.physicalcpu"] {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 {
                return Int(value)
            }
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }()

    /// Read the current load, or nil if `ps` couldn't be run. Blocks for as
    /// long as `ps` takes (well under a second).
    public static func read() -> SystemLoadReading? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,pcpu=,comm="]
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
        return reading(fromPS: output, excludingPid: ProcessInfo.processInfo.processIdentifier, fastCores: fastCoreCount)
    }

    /// The reading `ps -A -o pid=,pcpu=,comm=` output gives, leaving out
    /// `excludingPid` and every Wine process.
    static func reading(fromPS output: String, excludingPid: Int32, fastCores: Int) -> SystemLoadReading {
        var total = 0.0
        var byName: [String: Double] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let percent = Double(fields[1]) else { continue }
            let command = String(fields[2])
            guard pid != excludingPid, !isWine(command: command) else { continue }
            let cores = percent / 100
            total += cores
            let name = (command as NSString).lastPathComponent
            byName[name, default: 0] += cores
        }
        let top = byName
            .filter { $0.value >= 0.5 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { SystemLoadReading.Program(name: $0.key, cores: $0.value) }
        return SystemLoadReading(otherCores: total, fastCores: fastCores, topPrograms: Array(top))
    }

    /// Wine's own processes: the loader and server, and every Windows program
    /// it runs (named by its `.exe`, from a `winetemp-` directory).
    static func isWine(command: String) -> Bool {
        command.hasSuffix(".exe")
            || command.contains("/winetemp-")
            || command.contains("/wine/bin/")
            || command.contains("/wine/lib/")
    }
}
