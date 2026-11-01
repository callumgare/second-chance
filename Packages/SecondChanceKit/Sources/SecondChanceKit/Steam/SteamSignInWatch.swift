//
//  SteamSignInWatch.swift
//  SecondChanceKit
//
//  What a starting Steam does until it signs in, one check at a time.

import Foundation

/// What a starting Steam does until it signs in, one check at a time, for a
/// build's sign-in wait and a wrapp's alike. Each runs its own loop and acts
/// on what `check` returns: the build's is async, has deadlines and starts
/// Steam once more if it exits; the wrapp's is on a thread, waits for as
/// long as the player does, and stops when the wrapp quits.
public nonisolated struct SteamSignInWatch: Sendable {
    public enum Event: Equatable, Sendable {
        /// Starting, updating itself or connecting: a new stage
        /// (`SteamStartupWatch`).
        case startup(SteamStartupStage)
        /// Steam is showing its sign-in window. Only the first time it asks,
        /// and no more `startup` events after it.
        case needsSignIn(reason: String?)
        case signedIn
        /// Steam was missing from `exitedChecks` running checks in a row. It
        /// exits and starts again when it has updated itself, so one check
        /// that finds it missing proves nothing.
        case exited
    }

    private let client: SteamClientDriving
    private let exitedChecks: Int
    private let runningCheckInterval: TimeInterval
    private var startup = SteamStartupWatch()
    private var lastRunningCheck = Date()
    private var missingChecks = 0
    /// Whether Steam has asked for a sign-in.
    public private(set) var askedForSignIn = false

    /// Watch `client`, checking whether Steam is still running at most every
    /// `runningCheckInterval` seconds: every check when it's 0.
    public init(client: SteamClientDriving, exitedChecks: Int = 3, runningCheckInterval: TimeInterval = 0) {
        self.client = client
        self.exitedChecks = exitedChecks
        self.runningCheckInterval = runningCheckInterval
    }

    /// Look once: what has happened since the last check, in order.
    /// `signedIn` and `exited` end a wait; what follows is the caller's.
    public mutating func check(now: Date = Date()) -> [Event] {
        var events: [Event] = []
        switch client.loginState() {
        case .signedIn:
            return [.signedIn]
        case .needsCredentials(let reason) where !askedForSignIn:
            askedForSignIn = true
            events.append(.needsSignIn(reason: reason))
        case .pending, .needsCredentials:
            break
        }
        if !askedForSignIn, let stage = startup.check(client) {
            events.append(.startup(stage))
        }
        if now.timeIntervalSince(lastRunningCheck) >= runningCheckInterval {
            lastRunningCheck = now
            missingChecks = client.isRunning() ? 0 : missingChecks + 1
            if missingChecks >= exitedChecks {
                missingChecks = 0
                events.append(.exited)
            }
        }
        return events
    }

    /// Steam has been started again after it exited: a new start, which may
    /// update it all over again.
    public mutating func restarted() {
        startup = SteamStartupWatch()
        missingChecks = 0
    }
}
