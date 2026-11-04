//
//  WrappSteam.swift
//  WrappTemplate
//
//  Steam for a wrapp whose game needs it running (`wine-steam`,
//  `wine-steam-silent`): holding the one-Steam-at-a-time lock, bring the
//  shared sign-in in, start Steam and wait for it to sign in — asking the player to
//  when it can't — and afterwards stop it, save the sign-in back and take it
//  out of the wrapp again. docs/steam.md has the why.
//
//  The launcher runs on a background thread and is synchronous, so the async
//  client calls are waited on here.

import Foundation
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Steam")

nonisolated final class WrappSteam: @unchecked Sendable {
    /// Where Steam has got to, for the loading window.
    enum Status: Equatable {
        /// Starting, updating itself or connecting (`SteamStartupWatch`).
        case startup(SteamStartupStage)
        case waitingForSignIn
        case signedIn
        /// Steam is slow or stuck signing in (`SteamStallPolicy`), or no
        /// longer.
        case notice(SteamSignInNotice?)
    }

    enum Failure: Error {
        case inUse(SteamLockHolder)
        /// Steam exited before it signed in.
        case exited
        /// Steam got stuck signing in, even after starting it again and
        /// signing in afresh.
        case stuck
        case notStarted(String)
        /// The wrapp is quitting.
        case cancelled
    }

    let client: SteamClient
    private let store = SteamSessionStore()
    private let prefix: URL
    private let lock: SteamActiveLock
    private let state = NSLock()
    private var signedIn = false
    private var finished = false
    /// The player chose to sign in to Steam afresh, from the loading
    /// window's notice that it's stuck (`signInAfresh`).
    private var signInAfreshRequested = false

    /// Start Steam, holding `lock`, which this gives up when it finishes.
    /// `waitUntilSignedIn` then waits for it to sign in. Two steps, so the
    /// launcher holds this — and can stop Steam on quit — while the wait
    /// goes on: a wrapp quit mid-wait used to leave its Steam running.
    /// `status` gets what the loading window should say; `onOutputLine` each
    /// line Steam and the game it launches print.
    init(lock: SteamActiveLock, config: GameConfig, status: (Status) -> Void,
         onOutputLine: (@Sendable (String) -> Void)? = nil) throws {
        self.lock = lock
        prefix = config.winePrefix
        client = SteamClient(wrappPath: config.appPath, prefixDir: config.winePrefix,
                             gameExe: getGameLaunchInfo(config).gameExePath.map(URL.init(fileURLWithPath:)),
                             launch: config.launch, onOutputLine: onOutputLine)

        // A wrapp that was force-quit or crashed never stopped its Steam, which
        // is still running here, signed in. This wrapp holds the Steam lock, so
        // nothing else can be using it: end it before starting afresh.
        let server = client.wine.server
        if Blocking.wait({ await server.isRunning }) {
            logger.warning("A Wine session from an earlier run is still going here (it ended before it could stop Steam); stopping it")
            Blocking.wait { await server.stop() }
        }

        do {
            status(.startup(.starting))
            let client = client
            let store = store
            let restored = try Blocking.wait { try await client.restoreLogin(from: store) }
            logger.notice(restored ? "Restored the shared Steam sign-in" : "No saved Steam sign-in; Steam will ask for one")
            try Blocking.wait { try await client.start(silent: true) }
        } catch {
            finish(timeout: 30)
            throw error
        }
    }

    /// Wait for Steam to sign in, asking the player to when it shows its
    /// sign-in window, and saying meanwhile whether it's updating itself.
    /// Checks every second, so `finish` (a quit) ends the wait promptly with
    /// `.cancelled`. There's no time limit: an update on a slow connection
    /// takes as long as it takes, and the player may take their time signing
    /// in. Steam slow or stuck signing in is handled as `SteamStallPolicy`
    /// decides, as a build does, its notices shown in the loading window;
    /// taking up its offer to sign in afresh (`signInAfresh`) signs out of
    /// Steam, takes the sign-in out of the prefix, and starts Steam again to
    /// ask for one. Otherwise the wait ends early only if Steam exits.
    func waitUntilSignedIn(status: (Status) -> Void) throws {
        let client = client
        var watch = SteamSignInWatch(client: client, runningCheckInterval: 5)
        var policy = SteamStallPolicy(canOfferFreshSignIn: true)
        func startAgain() {
            Blocking.wait { await client.shutdown(timeout: 30) }
            watch.restarted()
            status(.startup(.starting))
            try? Blocking.wait { try await client.start(silent: true) }
        }
        func carryOut(_ actions: [SteamStallPolicy.Action]) throws {
            for action in actions {
                switch action {
                case .notice(let notice):
                    status(.notice(notice))
                case .restart:
                    logger.warning("Steam got stuck signing in; starting it again")
                    startAgain()
                case .fail:
                    finish(timeout: 30)
                    throw Failure.stuck
                }
            }
        }
        while true {
            if state.withLock({ finished }) { throw Failure.cancelled }
            if policy.notice == .stuck, state.withLock({ defer { signInAfreshRequested = false }; return signInAfreshRequested }) {
                logger.notice("Signing out of Steam and starting it again, as the player asked")
                try carryOut(policy.signingInAfresh())
                Blocking.wait { await client.shutdown(timeout: 30) }
                do {
                    try store.signOut()
                } catch {
                    logger.error("Couldn't sign out of Steam: \(error)")
                }
                SteamSessionStore.strip(from: prefix)
                startAgain()
            }
            for event in watch.check() {
                try carryOut(policy.handle(event))
                switch event {
                case .signedIn:
                    state.withLock { signedIn = true }
                    status(.signedIn)
                    return
                case .needsSignIn:
                    status(.waitingForSignIn)
                    Blocking.wait { await client.bringSignInWindowForward() }
                case .startup(let stage):
                    status(.startup(stage))
                case .quiet, .active, .stuck:
                    break
                case .exited:
                    logger.error("Steam exited before it signed in")
                    finish(timeout: 30)
                    throw Failure.exited
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Sign in to Steam afresh, from the loading window's notice that it's
    /// stuck: the wait signs out and starts Steam again. Any thread.
    func signInAfresh() {
        state.withLock { signInAfreshRequested = true }
    }

    /// Stop Steam, save the sign-in if Steam signed in this time, take it out
    /// of the wrapp, and give up the lock. Safe to call more than once.
    func finish(timeout: TimeInterval) {
        let first = state.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        let client = client
        Blocking.wait { await client.shutdown(timeout: timeout) }
        do {
            let result = try client.saveLogin(to: store, signedIn: state.withLock { signedIn })
            logger.notice("Steam sign-in: \(String(describing: result))")
        } catch {
            logger.warning("Couldn't save the Steam sign-in: \(error.localizedDescription)")
        }
        SteamSessionStore.strip(from: prefix)
        lock.release()
    }
}
