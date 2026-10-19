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
    /// How long the player gets to sign in to the window Steam shows.
    static let signInTimeout: TimeInterval = 30 * 60
    /// Steam's start and sign-in, which on a first run includes its update.
    static let startTimeout: TimeInterval = 20 * 60

    enum Failure: Error {
        case inUse(by: String?)
        case signInTimedOut
        case notStarted(String)
    }

    let client: SteamClient
    private let store = SteamSessionStore()
    private let prefix: URL
    private let lock: SteamActiveLock
    private let state = NSLock()
    private var signedIn = false
    private var finished = false

    /// Take the lock and start Steam signed in. `status` gets what the
    /// loading window should say.
    init(config: GameConfig, status: (String) -> Void) throws {
        switch try SteamActiveLock.acquire(bundleID: config.bundleId) {
        case .acquired(let lock):
            self.lock = lock
        case .heldBy(_, let bundleID):
            throw Failure.inUse(by: bundleID)
        }
        prefix = config.winePrefix
        client = SteamClient(wrappPath: config.appPath, prefixDir: config.winePrefix)

        // A wrapp that was force-quit or crashed never stopped its Steam, which
        // is still running here, signed in. This wrapp holds the Steam lock, so
        // nothing else can be using it: end it before starting afresh.
        if client.wine.isWineserverRunning() {
            logger.warning("A Wine session from an earlier run is still going here (it ended before it could stop Steam); stopping it")
            client.wine.stopWineserver()
        }

        do {
            status("Starting Steam…")
            let client = client
            let store = store
            let restored = try Self.waitThrowing { try await client.restoreLogin(from: store) }
            logger.notice(restored ? "Restored the shared Steam sign-in" : "No saved Steam sign-in; Steam will ask for one")
            try Self.waitThrowing { try await client.start(silent: true) }

            switch Self.wait({ await client.waitForLogin(timeout: Self.startTimeout) }) {
            case .signedIn:
                break
            case .pending:
                throw Failure.signInTimedOut
            case .needsCredentials:
                status("Sign in to Steam in its window — you can scan the QR code with the Steam app.")
                let deadline = Date().addingTimeInterval(Self.signInTimeout)
                while Self.wait({ await client.waitForLogin(timeout: 2) }) != .signedIn {
                    guard Date() < deadline else { throw Failure.signInTimedOut }
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            state.withLock { signedIn = true }
            status("Starting the game…")
        } catch {
            finish(timeout: 30)
            throw error
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
