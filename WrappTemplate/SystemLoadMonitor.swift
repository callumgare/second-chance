//
//  SystemLoadMonitor.swift
//  WrappTemplate
//
//  Watches for the Mac being too busy for the game to start promptly.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.SystemLoad")

/// Samples `SystemLoad` while the game loads and reports when the Mac is
/// heavily loaded, so the loading window can say why the wait is long.
///
/// Two readings in a row decide a change either way, so a moment's spike
/// neither raises the warning nor makes it flicker. Callbacks arrive on the
/// main queue: a reading while the Mac is heavily loaded, nil once it is not.
nonisolated final class SystemLoadMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.WrappTemplate.SystemLoadMonitor", qos: .utility)
    private let interval: TimeInterval
    private let onChange: @Sendable (SystemLoadReading?) -> Void
    private var timer: DispatchSourceTimer?
    private var heavyStreak = 0
    private var lightStreak = 0
    private var warning = false
    private var loggedFirstReading = false

    init(interval: TimeInterval = 5, onChange: @escaping @Sendable (SystemLoadReading?) -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval)
            timer.setEventHandler { [weak self] in self?.sample() }
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

    private func sample() {
        guard let reading = SystemLoad.read() else { return }
        if !loggedFirstReading {
            loggedFirstReading = true
            logger.notice("[Load] At launch \(reading.summary)")
        }
        if reading.isHeavy {
            heavyStreak += 1
            lightStreak = 0
            guard heavyStreak >= 2 else { return }
            if !warning {
                warning = true
                logger.warning("[Load] The Mac is heavily loaded: \(reading.summary). Wine may take minutes to start the game, or fail to")
            }
            let callback = onChange
            DispatchQueue.main.async { callback(reading) }
        } else {
            lightStreak += 1
            heavyStreak = 0
            guard warning, lightStreak >= 2 else { return }
            warning = false
            logger.notice("[Load] No longer heavily loaded: \(reading.summary)")
            let callback = onChange
            DispatchQueue.main.async { callback(nil) }
        }
    }
}
