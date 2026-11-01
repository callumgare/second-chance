//
//  SteamSignInWatch.swift
//  SecondChanceKit
//
//  What a starting Steam does until it signs in, one check at a time.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")

/// What a starting Steam does until it signs in, one check at a time, for a
/// build's sign-in wait and a wrapp's alike. Each runs its own loop and acts
/// on what `check` returns: the build's is async, has deadlines and starts
/// Steam once more if it exits; the wrapp's is on a thread, waits for as
/// long as the player does, and stops when the wrapp quits. The watch logs
/// what it sees, so either's log tells how far Steam got.
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
        /// Steam has written nothing to its logs for `quietLimit` (longer
        /// while the Mac is heavily loaded), and has neither signed in nor
        /// asked for credentials. Once per start.
        case stuck(quietFor: TimeInterval)
    }

    /// How long Steam may write nothing to its logs, before it has signed in
    /// or asked for credentials, before it counts as stuck. Any write shows
    /// it's still getting somewhere, an update's progress included. A
    /// healthy start on a fully loaded Mac once went 83 s without any sign
    /// at all (`LoadingStage.stallAfter`).
    public static let quietLimit: TimeInterval = 120
    /// How often a "still waiting" line is logged while nothing changes.
    static let waitingLogInterval: TimeInterval = 60
    /// Logged as a watch starts, and once Steam has signed in: the
    /// integration tests expect both in a Steam build's log and a Steam
    /// game's launch log.
    public static let waitingMarker = "[Sign-in] Waiting for Steam to sign in"
    public static let signedInMarker = "[Sign-in] Steam signed in"

    private let client: SteamClientDriving
    private let exitedChecks: Int
    private let runningCheckInterval: TimeInterval
    private let quietLimit: TimeInterval?
    private let isHeavilyLoaded: @Sendable () -> Bool
    private var startup = SteamStartupWatch()
    private var stage: SteamStartupStage?
    private var lastRunningCheck = Date()
    private var missingChecks = 0
    /// Whether Steam has asked for a sign-in.
    public private(set) var askedForSignIn = false
    /// When Steam last wrote to one of its logs, as far as the checks have
    /// seen, or when the watch (or Steam's restart) began if it hasn't since.
    public private(set) var lastLogActivity: Date
    private var lastLogWrite: Date?
    private var startedAt: Date
    private var lastWaitingLog: Date
    private var reportedStuck = false
    /// Whether the Mac was heavily loaded when last read, and when.
    private var heavyLoad: (heavy: Bool, at: Date)?

    /// Watch `client`, checking whether Steam is still running at most every
    /// `runningCheckInterval` seconds: every check when it's 0. A nil
    /// `quietLimit` never reports Steam stuck.
    public init(client: SteamClientDriving, exitedChecks: Int = 3, runningCheckInterval: TimeInterval = 0,
                quietLimit: TimeInterval? = Self.quietLimit,
                isHeavilyLoaded: @escaping @Sendable () -> Bool = { SystemLoad.read()?.isHeavy ?? false }) {
        self.client = client
        self.exitedChecks = exitedChecks
        self.runningCheckInterval = runningCheckInterval
        self.quietLimit = quietLimit
        self.isHeavilyLoaded = isHeavilyLoaded
        let now = Date()
        lastLogActivity = now
        startedAt = now
        lastWaitingLog = now
        lastLogWrite = client.lastLogWrite()
        logger.notice("\(Self.waitingMarker)")
    }

    /// Look once: what has happened since the last check, in order.
    /// `signedIn` and `exited` end a wait; what follows is the caller's.
    public mutating func check(now: Date = Date()) -> [Event] {
        var events: [Event] = []
        let write = client.lastLogWrite()
        if write != lastLogWrite {
            lastLogWrite = write
            lastLogActivity = now
        }
        switch client.loginState() {
        case .signedIn:
            logger.notice("\(Self.signedInMarker) after \(Self.duration(now.timeIntervalSince(startedAt)))")
            return [.signedIn]
        case .needsCredentials(let reason) where !askedForSignIn:
            askedForSignIn = true
            logger.notice("[Sign-in] Steam is asking for credentials\(reason.map { " (\($0))" } ?? "")")
            events.append(.needsSignIn(reason: reason))
        case .pending, .needsCredentials:
            break
        }
        if !askedForSignIn, let next = startup.check(client) {
            // An update's download is a new stage four times a second; only
            // a new step is worth the normal log.
            if next.message != stage?.message {
                logger.notice("[Sign-in] \(next.message)")
            } else if let text = next.downloadText {
                logger.debug("[Sign-in] \(next.message): \(text)")
            }
            stage = next
            events.append(.startup(next))
        }
        if now.timeIntervalSince(lastRunningCheck) >= runningCheckInterval {
            lastRunningCheck = now
            missingChecks = client.isRunning() ? 0 : missingChecks + 1
            if missingChecks >= exitedChecks {
                missingChecks = 0
                logger.warning("[Sign-in] Steam isn't running any more")
                events.append(.exited)
            }
        }
        let quiet = now.timeIntervalSince(lastLogActivity)
        if now.timeIntervalSince(lastWaitingLog) >= Self.waitingLogInterval {
            lastWaitingLog = now
            let doing = askedForSignIn ? "waiting for someone to sign in" : (stage?.message ?? "Starting Steam")
            logger.notice("[Sign-in] Still waiting after \(Self.duration(now.timeIntervalSince(startedAt))): \(doing); Steam's logs last changed \(Self.duration(quiet)) ago")
        }
        if !askedForSignIn, !reportedStuck, let limit = quietLimit, quiet >= limit, quiet >= limit * loadFactor(now: now) {
            reportedStuck = true
            logger.warning("[Sign-in] Steam looks stuck: nothing in its logs for \(Self.duration(quiet)), and it has neither signed in nor asked for credentials")
            events.append(.stuck(quietFor: quiet))
        }
        return events
    }

    /// Steam has been started again after it exited: a new start, which may
    /// update it all over again.
    public mutating func restarted() {
        startup = SteamStartupWatch()
        stage = nil
        missingChecks = 0
        let now = Date()
        lastLogActivity = now
        startedAt = now
        lastWaitingLog = now
        reportedStuck = false
        logger.notice("[Sign-in] Steam started again")
    }

    /// How much longer Steam gets for being quiet while the Mac is heavily
    /// loaded (`LoadingStage.heavyLoadFactor`). Read at most every 30 s, and
    /// only once Steam has been quiet for long enough for it to matter.
    private mutating func loadFactor(now: Date) -> TimeInterval {
        if heavyLoad.map({ now.timeIntervalSince($0.at) >= 30 }) ?? true {
            heavyLoad = (isHeavilyLoaded(), now)
        }
        return heavyLoad?.heavy == true ? LoadingStage.heavyLoadFactor : 1
    }

    /// "45s" or "3m 20s".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}
