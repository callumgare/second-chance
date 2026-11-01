//
//  SteamStallPolicy.swift
//  SecondChanceKit
//
//  What to do while Steam is slow or stuck signing in, for a build and a
//  wrapp alike.

import Foundation

/// What a window says while Steam is slow or stuck signing in.
public nonisolated enum SteamSignInNotice: Equatable, Sendable {
    /// Signing in is taking longer than it should. With `restartAt`, Steam
    /// will be started again then unless it gets going.
    case slow(restartAt: Date?)
    /// Stuck a second time and left running: the window offers to sign in
    /// to Steam afresh.
    case stuck

    /// The notice's heading.
    public var title: String {
        switch self {
        case .slow: return "Steam is taking longer than usual to sign in"
        case .stuck: return "Steam seems to be stuck signing in"
        }
    }

    /// What's happening and what comes next, as of `now`: a countdown, while
    /// Steam will be started again by itself.
    public func detail(now: Date = Date()) -> String {
        switch self {
        case .slow(let restartAt?):
            let left = max(0, restartAt.timeIntervalSince(now))
            return "If it hasn't signed in by then, it will be started again in \(Self.countdown(left))."
        case .slow(nil):
            return "It's still trying. If it doesn't get going, you'll be able to sign in to Steam again from scratch."
        case .stuck:
            return "It's still trying, and this goes away if it gets going. Or you can sign in to Steam again from scratch: "
                + "you'll need to sign in once more, and your other Nancy Drew games from Steam will ask you to sign in again once too."
        }
    }

    /// The button that takes up the offer to sign in afresh, on `.stuck`.
    public static let signInAgainButton = "Sign In Again"

    /// "1m 40s", or "40s" under a minute.
    static func countdown(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}

/// What to do while Steam is slow or stuck signing in, from what
/// `SteamSignInWatch` sees: a build and a wrapp each carry out what this
/// decides, in their own windows.
///
/// Steam's logs going quiet brings up a notice that signing in is taking
/// longer than it should, saying when Steam will be started again; it goes
/// if Steam writes something first. A Steam that then counts as stuck is
/// started again, as one that got stuck usually signs in on its next start.
/// Stuck again, it's left running, and the notice offers to sign in afresh
/// (sign out of Steam, take the sign-in out of the prefix, start Steam
/// again to ask for one); the notice goes if Steam gets going by itself.
/// Stuck after that, or a second time where nobody can sign in, it fails.
public nonisolated struct SteamStallPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        /// Show this notice, or none.
        case notice(SteamSignInNotice?)
        /// Stop Steam and start it again; then `restarted()` the watch.
        case restart
        /// Give up: Steam is stuck, and there's nothing more to try.
        case fail
    }

    private let canOfferFreshSignIn: Bool
    public private(set) var notice: SteamSignInNotice?
    private var stuckCount = 0

    /// `canOfferFreshSignIn` is whether someone is there to take up the
    /// offer to sign in afresh: not in a headless build.
    public init(canOfferFreshSignIn: Bool) {
        self.canOfferFreshSignIn = canOfferFreshSignIn
    }

    /// What to do about `event`, in order.
    public mutating func handle(_ event: SteamSignInWatch.Event) -> [Action] {
        switch event {
        case .quiet(let stuckAt):
            // Only the first time is Steam started again by itself.
            guard stuckCount < 2 else { return [] }
            return show(.slow(restartAt: stuckCount == 0 ? stuckAt : nil))
        case .active:
            guard case .slow = notice else { return [] }
            return show(nil)
        case .stuck:
            stuckCount += 1
            if stuckCount == 1 { return show(nil) + [.restart] }
            if stuckCount == 2, canOfferFreshSignIn { return show(.stuck) }
            return show(nil) + [.fail]
        case .signedIn, .needsSignIn:
            return show(nil)
        case .startup, .exited:
            return []
        }
    }

    /// The person took up the offer to sign in afresh: the caller signs out,
    /// and starts Steam again. Stuck after that, it fails.
    public mutating func signingInAfresh() -> [Action] {
        show(nil)
    }

    private mutating func show(_ next: SteamSignInNotice?) -> [Action] {
        guard next != notice else { return [] }
        notice = next
        return [.notice(next)]
    }
}
