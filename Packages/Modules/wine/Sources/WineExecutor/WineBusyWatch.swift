//
//  WineBusyWatch.swift
//  WineExecutor
//
//  `WATCH --wine.busy`: the step's Wine programs working, which the
//  installer's stall watch counts as progress (docs/wrappfile.md#signals).

import Foundation
import ProcessKit
import Synchronization
import WineKit
import WrappModuleKit

/// Fires when the tree's Wine programs, and none of another session's, use
/// more than a sliver of a core between two looks, or a new one starts.
nonisolated final class WineBusyWatch: WatchProbe {
    /// CPU, in cores, Wine's programs must use to count as working: its
    /// services idle at almost nothing.
    static let busyCores = 0.05

    let wine: Wine
    private let previous = Mutex<(cpu: [pid_t: Double], names: Set<String>, at: ContinuousClock.Instant)?>(nil)

    init(tree: URL) { wine = Wine(wrapp: tree) }

    func poll() -> [String: String]? {
        let programs = wine.server.programs(in: ProcessList.recent(maxAge: .seconds(1)))
        let cpu = Dictionary(programs.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: max)
        let names = Set(programs.map(\.name))
        let now = ContinuousClock.now
        return previous.withLock { previous in
            defer { previous = (cpu, names, now) }
            guard let before = previous else { return nil }
            let seconds = max(0.5, (now - before.at) / .seconds(1))
            let used = cpu.reduce(0.0) { total, entry in total + max(0, entry.value - (before.cpu[entry.key] ?? 0)) }
            let started = names.subtracting(before.names)
            guard used / seconds >= Self.busyCores || !started.isEmpty else { return nil }
            return started.isEmpty ? [:] : ["started": started.sorted().joined(separator: ",")]
        }
    }
}
