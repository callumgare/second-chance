//
//  LoadGate.swift
//  SecondChanceTests
//
//  Holding a game's integration test back while the Mac is too busy.

import Foundation
@testable import SecondChance

/// Decides whether the Mac is calm enough to test a game.
///
/// With all but one performance core taken by other programs, Wine takes
/// minutes to start or never does: a build then spends its full timeouts
/// failing, and the result says more about the load than the game. So before
/// each game the test waits a while for the load to ease, and if it doesn't,
/// reports the game as overloaded instead of testing it.
/// `sc test integration --ignore-load` (`IGNORE_LOAD=1` in the test's
/// environment) tests regardless, for deliberate stress runs.
enum LoadGate {
    /// `sc` sets `TEST_RUNNER_IGNORE_LOAD`; xcodebuild drops the prefix.
    static var ignoringLoad: Bool { ProcessInfo.processInfo.environment["IGNORE_LOAD"] == "1" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastGameWasOverloaded = false

    /// The reading that stayed heavy for the whole wait, or nil once the Mac
    /// isn't heavily loaded. After a game already held back, the next one
    /// waits only briefly, so a Mac that stays busy doesn't cost every game
    /// in the run a minute.
    static func overloadedReading(patience: TimeInterval = 60, interval: TimeInterval = 10) async -> SystemLoadReading? {
        let wait = lock.withLock { lastGameWasOverloaded } ? interval : patience
        let deadline = Date().addingTimeInterval(wait)
        var reading = SystemLoad.read()
        while let current = reading, current.isHeavy, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            reading = SystemLoad.read()
        }
        let overloaded = reading.flatMap { $0.isHeavy ? $0 : nil }
        lock.withLock { lastGameWasOverloaded = overloaded != nil }
        return overloaded
    }

    /// The current reading if the Mac is heavily loaded.
    static func heavyReadingNow() -> SystemLoadReading? {
        SystemLoad.read().flatMap { $0.isHeavy ? $0 : nil }
    }
}
