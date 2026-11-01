//
//  SteamDownloadMeter.swift
//  SecondChance
//
//  How far Steam's download of a game has got. Steam doesn't say as it goes:
//  its manifest's byte counts stay 0 until the end, its log gives only the
//  total and a rate once a minute, and preallocation fills the download
//  folder's blocks in the first second. macOS counts each process's network
//  traffic, though, and Steam downloads in Wine's processes. docs/steam.md
//  has the measurements.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.SteamDownloadMeter")

/// What Wine's programs have received over the network, as macOS counts it.
/// Tests stand in a fake.
protocol WineNetworkCounting: Sendable {
    /// The bytes Wine's running processes have received between them, or nil
    /// when that can't be read.
    func bytesReceived() async -> Int64?
}

/// Reads the counts from `nettop`, which needs no permission for them.
struct NettopNetworkCounter: WineNetworkCounting {
    func bytesReceived() async -> Int64? {
        do {
            let result = try await Process.output(of: "/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in"])
            guard result.succeeded else {
                logger.warning("nettop exited \(result.status): \(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                return nil
            }
            return Self.wineBytes(inNettop: result.output)
        } catch {
            logger.warning("Couldn't run nettop: \(error.localizedDescription)")
            return nil
        }
    }

    /// The bytes received by Wine's processes in one `nettop -P -L 1 -x -J
    /// bytes_in` sample: lines of `name.pid,bytes_in,`. Wine's are `wine`,
    /// `wineserver` and the Windows programs it names by their exe. The
    /// count for one connection moves between `wineserver` and the program
    /// using it from sample to sample, so only the sum means anything.
    nonisolated static func wineBytes(inNettop text: String) -> Int64? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.first?.contains("bytes_in") == true else { return nil }
        var total: Int64 = 0
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, let bytes = Int64(fields[1]) else { continue }
            let name = fields[0].split(separator: ".").dropLast().joined(separator: ".").lowercased()
            if name.hasPrefix("wine") || name.hasSuffix(".exe") { total += bytes }
        }
        return total
    }
}

/// One download's progress, from samples of what Wine has received.
nonisolated struct SteamDownloadMeter {
    /// The download's size, from Steam's log.
    let total: Int64
    /// What has arrived since the meter started.
    private(set) var received: Int64 = 0
    /// When `received` last grew.
    private(set) var lastGrowth: Date
    private var last: Int64?
    /// Recent samples, for the rate.
    private var recent: [(time: Date, received: Int64)] = []

    /// How far back the rate looks: long enough to smooth out bursts,
    /// short enough to follow a connection that slows.
    static let rateWindow: TimeInterval = 30

    init(total: Int64, now: Date = Date()) {
        self.total = total
        lastGrowth = now
    }

    /// Take in a sample of what Wine's processes have received between
    /// them. The first only sets where counting starts. A process that
    /// exits takes its count with it, so the sum can drop; only growth
    /// counts.
    mutating func add(_ count: Int64, at now: Date = Date()) {
        defer { last = count }
        guard let last else {
            recent = [(now, 0)]
            return
        }
        if count > last {
            received += count - last
            lastGrowth = now
        }
        recent.append((now, received))
        recent.removeAll { now.timeIntervalSince($0.time) > Self.rateWindow }
    }

    /// From 0 to 1. Never quite 1: Steam's figure leaves out its own traffic.
    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(received) / Double(total), 0.99)
    }

    /// How long nothing has arrived.
    func quietFor(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastGrowth)
    }

    /// Bytes a second over the last `rateWindow`, once there's 10 s of it.
    func bytesPerSecond(now: Date = Date()) -> Double? {
        guard let first = recent.first, let latest = recent.last else { return nil }
        let span = latest.time.timeIntervalSince(first.time)
        guard span >= 10 else { return nil }
        return Double(latest.received - first.received) / span
    }

    /// "1.2 GB of 2.4 GB, about 3 minutes left".
    func text(now: Date = Date()) -> String {
        let rate = bytesPerSecond(now: now).flatMap { $0 > 0 ? $0 : nil }
        return Self.text(done: Self.bytes.string(fromByteCount: min(received, total)),
                         of: Self.bytes.string(fromByteCount: total),
                         secondsLeft: rate.map { Double(max(total - received, 0)) / $0 })
    }

    /// "1.2 GB of 2.4 GB, about 3 minutes left", the time left in round
    /// figures: each case a whole sentence, so that it translates whole.
    static func text(done: String, of size: String, secondsLeft seconds: TimeInterval?) -> String {
        guard let seconds else { return String(localized: "\(done) of \(size)") }
        switch seconds {
        case ..<60:
            return String(localized: "\(done) of \(size), less than a minute left")
        case ..<90:
            return String(localized: "\(done) of \(size), about a minute left")
        case ..<(60 * 60):
            return String(localized: "\(done) of \(size), about \(Int((seconds / 60).rounded())) minutes left")
        case ..<(90 * 60):
            return String(localized: "\(done) of \(size), about an hour left")
        default:
            return String(localized: "\(done) of \(size), about \(Int((seconds / 3600).rounded())) hours left")
        }
    }

    /// Sizes as figures, "0 bytes" included rather than "Zero KB".
    /// Set up once, then only read: formatters are safe to share.
    nonisolated(unsafe) private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

}
