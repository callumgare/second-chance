//
//  WrappSteam.swift
//  WrappTemplate
//
//  Steam for a wrapp whose game needs it running (`wine-steam`,
//  `wine-steam-silent`): take the one-Steam-at-a-time lock, bring the shared
//  sign-in in, start Steam and wait for it to sign in — asking the player to
//  when it can't — and afterwards stop it, save the sign-in back and take it
//  out of the wrapp again. docs/steam.md has the why.
//
//  The launcher runs on a background thread and is synchronous, so the async
//  client calls are waited on here.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappTemplate.Steam")

nonisolated final class WrappSteam: @unchecked Sendable {
    /// Where Steam has got to, for the loading window.
    enum Status: Equatable {
        case starting
        /// Updating itself, which the bootstrapper reports as it goes: each
        /// new phase or download figure is a new status.
        case updating(SteamLogs.BootstrapPhase)
        /// Started, and connecting to Steam's servers to sign in.
        case connecting
        case waitingForSignIn
        case signedIn
    }

    enum Failure: Error {
        case inUse(SteamLockHolder)
        /// Steam exited before it signed in.
        case exited
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

    /// Take the lock and start Steam. `waitUntilSignedIn` then waits for it
    /// to sign in. Two steps, so the launcher holds this — and can stop
    /// Steam on quit — while the wait goes on: a wrapp quit mid-wait used to
    /// leave its Steam running. `status` gets what the loading window should say;
    /// `onOutputLine` each line Steam and the game it launches print.
    init(config: GameConfig, status: (Status) -> Void, onOutputLine: (@Sendable (String) -> Void)? = nil) throws {
        switch try SteamActiveLock.acquire(bundleID: config.bundleId) {
        case .acquired(let lock):
            self.lock = lock
        case .heldBy(let holder):
            throw Failure.inUse(holder)
        }
        prefix = config.winePrefix
        client = SteamClient(wrappPath: config.appPath, prefixDir: config.winePrefix,
                             gameExe: getGameLaunchInfo(config).gameExePath.map(URL.init(fileURLWithPath:)),
                             onOutputLine: onOutputLine)

        // A wrapp that was force-quit or crashed never stopped its Steam, which
        // is still running here, signed in. This wrapp holds the Steam lock, so
        // nothing else can be using it: end it before starting afresh.
        if client.wine.isWineserverRunning() {
            logger.warning("A Wine session from an earlier run is still going here (it ended before it could stop Steam); stopping it")
            client.wine.stopWineserver()
        }

        do {
            status(.starting)
            let client = client
            let store = store
            let restored = try Self.waitThrowing { try await client.restoreLogin(from: store) }
            logger.notice(restored ? "Restored the shared Steam sign-in" : "No saved Steam sign-in; Steam will ask for one")
            try Self.waitThrowing { try await client.start(silent: true) }
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
    /// in. The loading window says when Steam looks stuck, and the player
    /// can give up there. The wait ends early only if Steam exits.
    func waitUntilSignedIn(status: (Status) -> Void) throws {
        let client = client
        var asked = false
        var reported: Status = .starting
        var lastPhase = SteamLogs.BootstrapPhase.starting
        var lastRunningCheck = Date()
        var missingChecks = 0
        while true {
            if state.withLock({ finished }) { throw Failure.cancelled }
            switch client.loginState() {
            case .signedIn:
                logger.notice("Steam signed in")
                state.withLock { signedIn = true }
                status(.signedIn)
                return
            case .needsCredentials(let reason) where !asked:
                asked = true
                logger.notice("Steam is asking for credentials\(reason.map { " (\($0))" } ?? "")")
                reported = .waitingForSignIn
                status(.waitingForSignIn)
                Self.wait { await client.bringSignInWindowForward() }
            case .pending, .needsCredentials:
                break
            }
            if !asked {
                let phase = client.bootstrapPhase()
                if phase != lastPhase {
                    Self.logPhase(phase, after: lastPhase)
                    lastPhase = phase
                }
                // Once the update is in and the files check out, Steam is
                // starting again, as on any start.
                let now: Status = phase.isUpdating ? .updating(phase) : client.isConnecting() ? .connecting : .starting
                if now != reported {
                    reported = now
                    status(now)
                }
            }
            // An exited Steam will never sign in. It restarts itself after
            // an update, so it has to be missing from a few checks in a row.
            if Date().timeIntervalSince(lastRunningCheck) >= 5 {
                lastRunningCheck = Date()
                missingChecks = SteamClient.isSteamRunning() ? 0 : missingChecks + 1
                if missingChecks >= 3 {
                    logger.error("Steam exited before it signed in")
                    finish(timeout: 30)
                    throw Failure.exited
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// A line for each step of an update; download progress only every
    /// tenth of the way, as the bootstrapper reports it four times a second.
    private static func logPhase(_ phase: SteamLogs.BootstrapPhase, after previous: SteamLogs.BootstrapPhase) {
        switch phase {
        case .starting:
            break
        case .verifying:
            logger.notice("[Steam] Checking its files")
        case .verified:
            logger.notice("[Steam] Its files are up to date")
        case .downloading(let done, let total):
            guard let done, let total, total > 0 else {
                if case .downloading = previous { return }
                logger.notice("[Steam] Updating: downloading the update")
                return
            }
            var previousTenth = -1
            if case .downloading(let before?, _) = previous { previousTenth = Int(before * 10 / total) }
            let tenth = Int(done * 10 / total)
            if tenth != previousTenth {
                logger.notice("[Steam] Updating: downloaded \(done / 1024) of \(total / 1024) MB")
            }
        case .extracting:
            logger.notice("[Steam] Updating: extracting the update")
        case .installing:
            logger.notice("[Steam] Updating: installing the update")
        case .restarting:
            logger.notice("[Steam] Updated: starting the new version")
        }
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
        Self.wait { await client.shutdown(timeout: timeout) }
        do {
            let result = try client.saveLogin(to: store, signedIn: state.withLock { signedIn })
            logger.notice("Steam sign-in: \(String(describing: result))")
        } catch {
            logger.warning("Couldn't save the Steam sign-in: \(error.localizedDescription)")
        }
        SteamSessionStore.strip(from: prefix)
        lock.release()
    }

    // MARK: Waiting on async from a background thread

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func wait<T>(_ operation: @escaping @Sendable () async -> T) -> T where T: Sendable {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T?>(nil)
        Task.detached {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        guard let value = box.value else { preconditionFailure("the operation finished without a value") }
        return value
    }

    @discardableResult
    private static func waitThrowing<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        try wait { () async -> Result<T, Error> in
            do { return .success(try await operation()) } catch { return .failure(error) }
        }.get()
    }
}
