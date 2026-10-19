//
//  SteamActiveLock.swift
//  Shared
//
//  Only one wrapp at a time runs Steam. Two signed in to the same account
//  would knock each other off, and both would save the session back when
//  they quit, racing each other.

import Foundation

nonisolated final class SteamActiveLock: @unchecked Sendable {
    enum Outcome {
        case acquired(SteamActiveLock)
        /// Another process holds it. `bundleID` names the wrapp, when it said.
        case heldBy(pid: Int32?, bundleID: String?)
    }

    private let fd: Int32
    private let state = NSLock()
    private var released = false

    private init(fd: Int32) { self.fd = fd }

    /// Try to take the lock in `root` (the session store's directory) for the
    /// wrapp `bundleID`. It is an `flock`, so it is released when this
    /// process exits, however it exits — a crashed wrapp never leaves it held.
    static func acquire(root: URL = SteamSessionStore.defaultRoot, bundleID: String) throws -> Outcome {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("active-wrapp.lock").path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            close(fd)
            let lines = holder.split(whereSeparator: \.isNewline).map(String.init)
            return .heldBy(pid: lines.first.flatMap { Int32($0) }, bundleID: lines.count > 1 ? lines[1] : nil)
        }
        ftruncate(fd, 0)
        let record = "\(getpid())\n\(bundleID)\n"
        _ = record.withCString { pwrite(fd, $0, strlen($0), 0) }
        return .acquired(SteamActiveLock(fd: fd))
    }

    /// Give it up before the process exits. Safe to call more than once.
    func release() {
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
