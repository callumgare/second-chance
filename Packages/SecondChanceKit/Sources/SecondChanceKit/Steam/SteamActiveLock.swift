//
//  SteamActiveLock.swift
//  Shared
//
//  Only one wrapp at a time runs Steam. Two signed in to the same account
//  would knock each other off, and both would save the session back when
//  they quit, racing each other.

import Foundation
import Logging
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")

nonisolated public final class SteamActiveLock: @unchecked Sendable {
    public enum Outcome {
        case acquired(SteamActiveLock)
        /// Another process holds it.
        case heldBy(SteamLockHolder)
    }

    /// The steam module's `steam` lock (`Modules/steam/stores`), which a
    /// build's steps using Steam's sign-in store hold too, and which a 1.1.0
    /// app reaches through the link left at its old place
    /// (`SecondChance/Steam/active-wrapp.lock`, `AppMigrations`).
    public static var defaultFile: URL { StoreLocations.sharedLockFile(owner: "steam", name: "steam") }

    private let file: URL
    private let token: UUID
    private let state = NSLock()
    private var released = false

    private init(file: URL, token: UUID) {
        self.file = file
        self.token = token
    }

    /// Try to take the lock in `root` (a test's folder) for the wrapp
    /// `bundleID`.
    public static func acquire(root: URL, bundleID: String, token: UUID = UUID()) throws -> Outcome {
        try acquire(file: root.appendingPathComponent("active-wrapp.lock"), bundleID: bundleID, token: token)
    }

    /// Try to take the lock for the wrapp `bundleID`, for `token`: a build
    /// gives its runner's, so its steps that use Steam's stores share it
    /// (`ProcessLocks`). An `flock`, so it is released when this process
    /// exits, however it exits: a crashed wrapp never leaves it held.
    public static func acquire(file: URL = defaultFile, bundleID: String, token: UUID = UUID()) throws -> Outcome {
        guard try ProcessLocks.tryTake(file, token: token, holder: bundleID) else {
            let holder = ProcessLocks.holder(of: file)
            return .heldBy(SteamLockHolder(pid: holder.pid, bundleID: holder.name))
        }
        return .acquired(SteamActiveLock(file: file, token: token))
    }

    /// What came of waiting for the lock (`take`).
    public enum Taking {
        case acquired(SteamActiveLock)
        /// The person chose to leave the holder be.
        case cancelled(SteamLockHolder)
        /// Still held: there was nobody to ask, or the holder wouldn't quit.
        case held(SteamLockHolder)
    }

    /// Take the lock, asking `ask` what to do each time another process
    /// holds it: try again once they've quit it themselves, have it quit
    /// for them, or give up. `ask` gives nil when there's nobody to ask.
    public static func take(root: URL, bundleID: String, token: UUID = UUID(),
                            ask: (SteamLockHolder) async -> SteamLockHolder.Choice?) async throws -> Taking {
        try await take(file: root.appendingPathComponent("active-wrapp.lock"), bundleID: bundleID, token: token, ask: ask)
    }

    public static func take(file: URL = defaultFile, bundleID: String, token: UUID = UUID(),
                            ask: (SteamLockHolder) async -> SteamLockHolder.Choice?) async throws -> Taking {
        while true {
            switch try acquire(file: file, bundleID: bundleID, token: token) {
            case .acquired(let lock):
                return .acquired(lock)
            case .heldBy(let holder):
                logger.notice("Steam is in use by \(holder.name ?? "another process") (\(holder.bundleID ?? "unknown"), pid \(holder.pid.map(String.init) ?? "unknown"))")
                switch await ask(holder) {
                case nil:
                    return .held(holder)
                case .tryAgain:
                    continue
                case .cancel:
                    return .cancelled(holder)
                case .quitHolder:
                    let gone = await holder.quit()
                    if !gone { return .held(holder) }
                }
            }
        }
    }

    /// Give it up before the process exits. Safe to call more than once.
    public func release() {
        let first = state.withLock {
            defer { released = true }
            return !released
        }
        guard first else { return }
        ProcessLocks.release(file, token: token)
    }

    deinit { release() }
}
