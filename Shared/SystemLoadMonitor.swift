//
//  SystemLoadMonitor.swift
//  Shared
//
//  Watches how busy the Mac is for as long as Wine work runs, so a log
//  says when the Mac was too busy, not only how busy it was at start-up.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.SystemLoad")

/// Samples `SystemLoad` while Wine work runs — a build, or a wrapp's whole
/// run — and logs only while the Mac is heavily loaded: a warning when it
/// becomes so, a reminder every `reminderInterval` while it stays so, and a
/// notice when it stops. The header already has the load at start-up, and a
/// light load is not worth a line. Two readings in a row decide a change
/// either way, so a moment's spike neither raises the warning nor makes it
/// flicker. Every reading also goes into `history`, which a failure summary
/// quotes.
///
/// It samples often while things are starting, when load decides whether
/// Wine starts at all; `slowDown()` switches to the steady-state interval
/// once the game is running.
///
/// An observer (the wrapp's loading window) hears on the main queue: a
/// reading while the Mac is heavily loaded, nil once it is not.
nonisolated final class SystemLoadMonitor: @unchecked Sendable {
    /// While a build runs or a game starts.
    static let busyInterval: TimeInterval = 5
    /// Once the game is running.
    static let steadyInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.Shared.SystemLoadMonitor", qos: .utility)
    private let reminderInterval: TimeInterval
    private var interval: TimeInterval
    private var observer: (@Sendable (SystemLoadReading?) -> Void)?
    private var timer: DispatchSourceTimer?
    private var heavyStreak = 0
    private var lightStreak = 0
    private var heavySince: Date?
    private var lastReminder: Date?

    init(interval: TimeInterval = SystemLoadMonitor.busyInterval, reminderInterval: TimeInterval = 300) {
        self.interval = interval
        self.reminderInterval = reminderInterval
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
        }
    }

    /// Sample at the steady-state interval from now on.
    func slowDown() {
        queue.async {
            guard self.interval != Self.steadyInterval else { return }
            self.interval = Self.steadyInterval
            self.timer?.schedule(deadline: .now() + Self.steadyInterval, repeating: Self.steadyInterval)
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
        if reading.isHeavy {
            heavyStreak += 1
            lightStreak = 0
            guard heavyStreak >= 2 else { return }
            if let since = heavySince {
                if let last = lastReminder, now.timeIntervalSince(last) >= reminderInterval {
                    lastReminder = now
                    logger.warning("[Load] Still heavily loaded after \(Int(now.timeIntervalSince(since) / 60)) min: \(reading.summary)")
                }
            } else {
                heavySince = now
                lastReminder = now
                logger.warning("[Load] The Mac is heavily loaded: \(reading.summary). Wine may take minutes to start programs, or fail to")
            }
            notify(reading)
        } else {
            lightStreak += 1
            heavyStreak = 0
            guard let since = heavySince, lightStreak >= 2 else { return }
            heavySince = nil
            lastReminder = nil
            logger.notice("[Load] No longer heavily loaded, after \(Int(now.timeIntervalSince(since) / 60)) min: \(reading.summary)")
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
