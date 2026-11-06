//
//  PuppetAudio.swift
//  PuppetProtocol
//
//  How loud a program is: the levels the helper's `audio` request measures
//  (the wine module's InProcessHelpers/audio_levels.m), and `sc puppet
//  audio`'s tap, and the one verdict both come to — silent (every 0.1 s
//  window under -60 dBFS), sound, or clipping.

import Foundation

/// Sound levels, a 0.1 s window each, and what they add up to: from the
/// helper's `audio` reply, or from `sc puppet audio`'s tap, which write
/// them alike (`level t= peak= rms=`).
nonisolated public struct AudioLevel: Sendable, Equatable {
    /// The end of its window, in seconds from the start of listening.
    public var time: Double
    /// The loudest sample, 0...1 (full scale).
    public var peak: Double
    public var rms: Double

    /// A `level t= peak= rms=` line.
    public init?(line: String) {
        guard line.hasPrefix("level ") else { return nil }
        let fields = Dictionary(line.split(separator: " ").dropFirst().compactMap { word -> (String, Double)? in
            let parts = word.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }, uniquingKeysWith: { first, _ in first })
        guard let time = fields["t"], let peak = fields["peak"], let rms = fields["rms"] else { return nil }
        self.init(time: time, peak: peak, rms: rms)
    }

    public init(time: Double, peak: Double, rms: Double) {
        self.time = time
        self.peak = peak
        self.rms = rms
    }

    /// Below this a window is silence: -60 dBFS.
    public static let silence = 0.001
    /// At or above this a sample is at full scale.
    public static let fullScale = 0.999

    public static func decibels(_ value: Double) -> String {
        value <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(value))
    }

    /// One line: silent, sound or clipping.
    public static func summary(_ levels: [AudioLevel]) -> String {
        guard !levels.isEmpty else { return "no samples: nothing was measured" }
        let sounding = levels.filter { $0.peak >= silence }
        let clipped = levels.filter { $0.peak >= fullScale }
        let peak = levels.map(\.peak).max() ?? 0, rms = levels.map(\.rms).max() ?? 0
        let loudest = "peak \(decibels(peak)) dBFS, RMS up to \(decibels(rms)) dBFS"
        if sounding.isEmpty { return "silent: every window under -60 dBFS (\(loudest))" }
        if !clipped.isEmpty { return "clipping: \(clipped.count) of \(levels.count) windows reach full scale; sound in \(sounding.count) (\(loudest))" }
        return "sound in \(sounding.count) of \(levels.count) windows (\(loudest))"
    }

    /// A row a second: its windows' RMS as bars (· for silence), and its
    /// loudest peak and RMS.
    public static func rows(_ levels: [AudioLevel], perRow: Int = 10) -> [String] {
        let bars = Array("▁▂▃▄▅▆▇█")
        return stride(from: 0, to: levels.count, by: perRow).map { start in
            let row = levels[start..<min(start + perRow, levels.count)]
            let picture = String(row.map { level -> Character in
                guard level.peak >= silence, level.rms > 0 else { return "·" }
                let db = max(-60, min(0, 20 * log10(level.rms)))
                return bars[min(bars.count - 1, Int((db + 60) / 60 * Double(bars.count)))]
            })
            let padded = picture.padding(toLength: perRow, withPad: " ", startingAt: 0)
            let from = String(format: "%5.1fs", (row.first?.time ?? 0) - 0.1)
            return "\(from)  \(padded)  peak \(decibels(row.map(\.peak).max() ?? 0)), rms \(decibels(row.map(\.rms).max() ?? 0))"
        }
    }
}

/// The helper's reply to `audio`: `ok <verdict> windows=… streams=… format=…
/// hooked=0|1`, then a `level` line a window.
nonisolated public struct PuppetAudio: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        case silent, sound, clipping
    }

    public let levels: [AudioLevel]
    /// How many sound streams the game has opened since it started.
    public let streams: Int
    /// The streams' sample format (`float32`, `int16`…), as the helper read it.
    public let format: String
    /// Whether the game has loaded Wine's Core Audio driver, which the
    /// measure wraps: it hasn't opened any sound if not.
    public let hooked: Bool

    /// From an `audio` reply; nil for an error.
    public init?(_ reply: PuppetReply) {
        guard reply.isOK else { return nil }
        let fields = reply.fields
        levels = reply.text.split(separator: "\n").dropFirst().compactMap { AudioLevel(line: String($0)) }
        streams = fields["streams"].flatMap(Int.init) ?? 0
        format = fields["format"] ?? "unknown"
        hooked = fields["hooked"] == "1"
    }

    /// Worked out from the levels, as `AudioLevel.summary` does.
    public var verdict: Verdict {
        if !levels.contains(where: { $0.peak >= AudioLevel.silence }) { return .silent }
        return levels.contains(where: { $0.peak >= AudioLevel.fullScale }) ? .clipping : .sound
    }

    /// One line: the verdict and the loudest levels, and where they came from.
    public var summary: String {
        let source = hooked ? "\(streams) stream\(streams == 1 ? "" : "s"), \(format)"
            : "the game hasn't opened Wine's Core Audio output"
        return "\(AudioLevel.summary(levels)); \(source)"
    }
}
