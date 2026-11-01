//
//  SteamActiveLock.swift
//  Shared
//
//  Only one wrapp at a time runs Steam. Two signed in to the same account
//  would knock each other off, and both would save the session back when
//  they quit, racing each other.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Steam")

nonisolated public final class SteamActiveLock: @unchecked Sendable {
    public enum Outcome {
        case acquired(SteamActiveLock)
        /// Another process holds it.
        case heldBy(SteamLockHolder)
    }

    private let fd: Int32
    private let state = NSLock()
    private var released = false

    private init(fd: Int32) { self.fd = fd }

    /// Try to take the lock in `root` (the session store's directory) for the
    /// wrapp `bundleID`. It is an `flock`, so it is released when this
    /// process exits, however it exits — a crashed wrapp never leaves it held.
    /// Close-on-exec, so no program started from here (Wine, Steam) carries
    /// the lock on after the process that took it.
    public static func acquire(root: URL = SteamSessionStore.defaultRoot, bundleID: String) throws -> Outcome {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("active-wrapp.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            close(fd)
            let lines = holder.split(whereSeparator: \.isNewline).map(String.init)
            return .heldBy(SteamLockHolder(pid: lines.first.flatMap { Int32($0) }, bundleID: lines.count > 1 ? lines[1] : nil))
        }
        ftruncate(fd, 0)
        let record = "\(getpid())\n\(bundleID)\n"
        _ = record.withCString { pwrite(fd, $0, strlen($0), 0) }
        return .acquired(SteamActiveLock(fd: fd))
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
    public static func take(root: URL = SteamSessionStore.defaultRoot, bundleID: String,
                            ask: (SteamLockHolder) async -> SteamLockHolder.Choice?) async throws -> Taking {
        while true {
            switch try acquire(root: root, bundleID: bundleID) {
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
                    let gone = await Task.detached { holder.quit() }.value
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
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }
}
