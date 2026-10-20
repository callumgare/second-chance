//
//  RunningSteam.swift
//  SecondChance
//
//  The Steam a build has running, so that quitting Second Chance stops it.
//  Without this, quitting while Steam waited for a sign-in left Steam's
//  window open, its Wine session running in a temporary wrapp that the quit
//  then deleted. See docs/steam.md.

import Foundation

/// One build's Steam: whether it's running, and whether it signed in (which
/// decides whether stopping it saves the session). Whoever claims the stop —
/// the build itself, or a quit — does it, and only once.
nonisolated final class SteamRun: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var _signedIn = false

    var signedIn: Bool {
        get { lock.withLock { _signedIn } }
        set { lock.withLock { _signedIn = newValue } }
    }

    func started() { lock.withLock { running = true } }

    /// True for the one caller that should stop Steam: it was running, and
    /// nobody else has claimed stopping it.
    func claimStop() -> Bool {
        lock.withLock {
            defer { running = false }
            return running
        }
    }
}

/// The stops for every build's running Steam, for the app to run on quit.
nonisolated final class RunningSteam: @unchecked Sendable {
    static let shared = RunningSteam()

    typealias Stop = @Sendable () async -> Void
    private let lock = NSLock()
    private var stops: [UUID: Stop] = [:]

    func register(_ stop: @escaping Stop) -> UUID {
        let id = UUID()
        lock.withLock { stops[id] = stop }
        return id
    }

    func unregister(_ id: UUID) {
        _ = lock.withLock { stops.removeValue(forKey: id) }
    }

    var isEmpty: Bool { lock.withLock { stops.isEmpty } }

    /// Run every registered stop, and forget them.
    func stopAll() async {
        let all = lock.withLock {
            defer { stops.removeAll() }
            return Array(stops.values)
        }
        for stop in all { await stop() }
    }
}
