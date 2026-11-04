//
//  ProcessLocks.swift
//  WrappFormat
//
//  The `flock`s this process holds on lock files, by whom: a store's lock
//  (decision 23 of the builders plan) and Steam's one-at-a-time lock are
//  the same file, so a build that holds one holds the other.

import Darwin
import Foundation
import Synchronization

/// An `flock` on a lock file, held for a token: another process waits, as
/// does another token in this one, as two builds side by side in one app
/// must exclude each other; the same token takes it again, counted. The
/// file names its holder, its pid then a line of its own (an app's name or
/// bundle id), as Steam's lock always has, for whoever waits to say who.
/// Close-on-exec, so no program started from here (Wine, Steam) carries the
/// lock on after the process that took it, and an `flock` goes when its
/// process does, however it ends.
public nonisolated enum ProcessLocks {
    private struct Held {
        var descriptor: Int32
        var token: UUID
        var count: Int
    }

    private static let held = Mutex<[String: Held]>([:])

    /// Whether `file` is now locked for `token`: taken now, or held for it
    /// already. False while another process or token holds it.
    public static func tryTake(_ file: URL, token: UUID, holder: String) throws -> Bool {
        try held.withLock { held in
            if var mine = held[file.path] {
                guard mine.token == token else { return false }
                mine.count += 1
                held[file.path] = mine
                return true
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                return false
            }
            ftruncate(descriptor, 0)
            let record = "\(getpid())\n\(holder)\n"
            _ = record.withCString { pwrite(descriptor, $0, strlen($0), 0) }
            held[file.path] = Held(descriptor: descriptor, token: token, count: 1)
            return true
        }
    }

    /// One of `token`'s holds on `file` let go; the last unlocks it.
    public static func release(_ file: URL, token: UUID) {
        held.withLock { held in
            guard var mine = held[file.path], mine.token == token else { return }
            mine.count -= 1
            if mine.count > 0 {
                held[file.path] = mine
                return
            }
            ftruncate(mine.descriptor, 0)
            flock(mine.descriptor, LOCK_UN)
            close(mine.descriptor)
            held[file.path] = nil
        }
    }

    /// What `file` says holds it: its pid, then the line after.
    public static func holder(of file: URL) -> (pid: Int32?, name: String?) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return (nil, nil) }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return (lines.first.flatMap { Int32($0) }, lines.count > 1 ? lines[1] : nil)
    }
}
