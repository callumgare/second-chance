//
//  MainThreadWatchdog.swift
//  SecondChance
//
//  Debug builds: logs each time the main thread stays busy long enough for
//  the window to stop responding, so the log shows which step of a build
//  froze it. Work that blocks (a subprocess waited for, a large copy) belongs
//  off the main thread, through `Blocking.run`.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.MainThreadWatchdog")

nonisolated enum MainThreadWatchdog {
    /// Long enough to notice, as a click that does nothing for this long does.
    static let threshold: TimeInterval = 0.25

    static func start() {
        #if DEBUG
        let thread = Thread {
            while true {
                let answered = DispatchSemaphore(value: 0)
                let asked = Date()
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + threshold) == .timedOut {
                    answered.wait()
                    let busy = Date().timeIntervalSince(asked)
                    logger.warning("[Hang] The main thread was busy for \(String(format: "%.2f", busy)) s")
                }
                // How often to look: a stall shorter than the threshold
                // isn't one, so this needn't be more often than that.
                Thread.sleep(forTimeInterval: threshold)
            }
        }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .utility
        thread.start()
        #endif
    }
}
