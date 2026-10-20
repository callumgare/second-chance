//
//  SystemLoadMonitor.swift
//  Shared
//
//  Samples how busy the Mac is for as long as Wine work runs, so a log
//  shows the load at the moment something went wrong, not only at start-up.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.SystemLoad")

/// Samples `SystemLoad` every `interval` while Wine work runs: a build, or a
/// wrapp's whole run.
///
/// It logs the first reading as a notice, one reading a minute at `.debug`
/// (kept in every saved log, kept off the terminal), and a warning when the
/// Mac becomes heavily loaded, and a notice when it stops being. Two readings
/// in a row decide a change either way, so a moment's spike neither raises
/// the warning nor makes it flicker. Every reading also goes into `history`,
/// which a failure summary quotes.
///
/// An observer (the wrapp's loading window) hears on the main queue: a
/// reading while the Mac is heavily loaded, nil once it is not.
nonisolated final class SystemLoadMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.Shared.SystemLoadMonitor", qos: .utility)
    private let context: String
    private let interval: TimeInterval
    private let logInterval: TimeInterval
    private var observer: (@Sendable (SystemLoadReading?) -> Void)?
    private var timer: DispatchSourceTimer?
    private var heavyStreak = 0
    private var lightStreak = 0
    private var warning = false
    private var lastLogged: Date?

    /// - Parameter context: What the load is being watched during, for the
    ///   first line: "the build", "the launch".
    init(context: String, interval: TimeInterval = 5, logInterval: TimeInterval = 60) {
        self.context = context
        self.interval = interval
        self.logInterval = logInterval
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval)
            // Holds the monitor until `stop()`, so a caller needn't keep it.
            timer.setEventHandler { self.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.lastLogged = nil
        }
    }

    /// Hear about heavy load from now on, or stop hearing (nil). An observer
    /// set while the Mac is already heavily loaded hears so at the next
    /// reading.
    func observe(_ observer: (@Sendable (SystemLoadReading?) -> Void)?) {
        queue.async { self.observer = observer }
    }

    private func sample() {
        guard let reading = SystemLoad.read() else { return }
        let now = Date()
        SystemLoadHistory.shared.record(reading, at: now)
        if let last = lastLogged {
            if now.timeIntervalSince(last) >= logInterval {
                lastLogged = now
                logger.debug("[Load] \(reading.summary)")
            }
        } else {
            lastLogged = now
            logger.notice("[Load] At the start of \(context): \(reading.summary)")
        }
        if reading.isHeavy {
            heavyStreak += 1
            lightStreak = 0
            guard heavyStreak >= 2 else { return }
            if !warning {
                warning = true
                logger.warning("[Load] The Mac is heavily loaded: \(reading.summary). Wine may take minutes to start programs, or fail to")
            }
            notify(reading)
        } else {
            lightStreak += 1
            heavyStreak = 0
            guard warning, lightStreak >= 2 else { return }
            warning = false
            logger.notice("[Load] No longer heavily loaded: \(reading.summary)")
            notify(nil)
        }
    }

    private func notify(_ reading: SystemLoadReading?) {
        guard let observer else { return }
        DispatchQueue.main.async { observer(reading) }
    }
}

/// The readings monitors took in the last few minutes, for a failure
/// summary: a failure's cause is often load that has passed by the time the
/// failure is noticed.
nonisolated final class SystemLoadHistory: @unchecked Sendable {
    static let shared = SystemLoadHistory()

    /// How far back readings are kept.
    static let window: TimeInterval = 600

    private let lock = NSLock()
    private var readings: [(date: Date, reading: SystemLoadReading)] = []

    func record(_ reading: SystemLoadReading, at date: Date) {
        lock.withLock {
            readings.append((date, reading))
            readings.removeAll { date.timeIntervalSince($0.date) > Self.window }
        }
    }

    /// "1.2–7.9 cores busy over the last 10 min (busiest at 17:28:05: …)",
    /// or nil when no monitor has run recently.
    func summary(now: Date = Date()) -> String? {
        let recent = lock.withLock { readings.filter { now.timeIntervalSince($0.date) <= Self.window } }
        return Self.summary(of: recent, now: now)
    }

    static func summary(of recent: [(date: Date, reading: SystemLoadReading)], now: Date) -> String? {
        guard let first = recent.first,
              let busiest = recent.max(by: { $0.reading.otherCores < $1.reading.otherCores }),
              let quietest = recent.min(by: { $0.reading.otherCores < $1.reading.otherCores })
        else { return nil }
        let minutes = max(1, Int((now.timeIntervalSince(first.date) / 60).rounded(.up)))
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let range = String(format: "%.1f–%.1f", quietest.reading.otherCores, busiest.reading.otherCores)
        var text = "\(range) cores busy over the last \(minutes) min"
        text += " (busiest at \(time.string(from: busiest.date)): \(busiest.reading.summary))"
        if recent.contains(where: { $0.reading.isHeavy }) {
            text += "; heavily loaded at times"
        }
        return text
    }
}
