//
//  SystemLoad.swift
//  ProcessKit
//
//  How much of the Mac's CPU other programs are using.

import Foundation
import WrappLogging

/// One reading of how busy the Mac is with work other than our own.
///
/// What starves Wine is other programs taking the performance cores, so that
/// is what this measures: the CPU used by every process except Wine's and the
/// caller's own, in cores, against the Mac's performance-core count. The load
/// average is no use for this — Wine's own threads, starved, push it past 100
/// on a ten-core Mac.
nonisolated public struct SystemLoadReading: Sendable, Equatable {
    /// Cores' worth of CPU other programs are using (`ps`'s decaying average).
    public let otherCores: Double
    /// Performance cores (all cores on a Mac without performance levels).
    public let fastCores: Int
    /// The programs using the most, by name, with their cores' worth.
    public let topPrograms: [Program]

    public struct Program: Sendable, Equatable {
        public let name: String
        public let cores: Double

        public init(name: String, cores: Double) {
            self.name = name
            self.cores = cores
        }
    }

    public init(otherCores: Double, fastCores: Int, topPrograms: [Program]) {
        self.otherCores = otherCores
        self.fastCores = fastCores
        self.topPrograms = topPrograms
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

nonisolated public enum SystemLoad {
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
    ///
    /// `excludingDescendants` leaves out everything this process started, and
    /// what that started, as well as itself: the integration tests' own
    /// builds (their copies, disc mounts and signing) aren't other programs
    /// the Mac is busy with.
    public static func read(excludingDescendants: Bool = false) -> SystemLoadReading? {
        guard let processes = ProcessList.recent(maxAge: .seconds(2)) else { return nil }
        return reading(from: processes, excluding: ProcessInfo.processInfo.processIdentifier,
                       andDescendants: excludingDescendants, fastCores: fastCoreCount)
    }

    /// The reading `processes` give, leaving out `excluded`, everything it
    /// started when `andDescendants`, and this user's Wine processes. Another
    /// user's Wine (a game in a background login) is load like any other.
    static func reading(from processes: ProcessList, excluding excluded: pid_t, andDescendants: Bool,
                        fastCores: Int) -> SystemLoadReading {
        var total = 0.0
        var byName: [String: Double] = [:]
        for process in processes.entries {
            guard process.pid != excluded, !(process.isWine && process.isMine),
                  !(andDescendants && processes.descends(process.pid, from: excluded)) else { continue }
            let cores = process.cpuPercent / 100
            total += cores
            byName[process.name, default: 0] += cores
        }
        let top = byName
            .filter { $0.value >= 0.5 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { SystemLoadReading.Program(name: $0.key, cores: $0.value) }
        return SystemLoadReading(otherCores: total, fastCores: fastCores, topPrograms: Array(top))
    }
}
