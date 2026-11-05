//
//  DiscCopy.swift
//  WineExecutor
//
//  Copies a game disc into the wrapp in one pass that can be cancelled and
//  says how far it has got. Only the files' contents are copied: not their
//  extended attributes, resource forks or Finder info (which would make the
//  wrapp's codesign fail), nor a CD's read-only modes (which left copies
//  nothing could delete). That used to take three passes: a copy, `xattr -cr`
//  and `chmod -R u+w`.

import Darwin
import Foundation
import Logging
import ProcessKit
import Synchronization

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.DiscCopy")

public nonisolated enum DiscCopy {
    /// How far a copy has got, in bytes.
    public struct Progress: Sendable {
        public let copied: Int64
        public let total: Int64?
    }

    /// Copy the folder `source` to `destination`, which mustn't exist yet.
    /// `progress` is called as the copy goes, from the copying thread, at
    /// most a few times a second. Throws `CancellationError` once the task is
    /// cancelled, leaving what was copied for the caller to remove.
    public static func copy(from source: URL, to destination: URL, total: Int64?,
                            progress: @escaping @Sendable (Progress) -> Void) async throws {
        let state = CopyState(total: total, progress: progress)
        try await withTaskCancellationHandler {
            try await Blocking.run {
                let context = Unmanaged.passUnretained(state).toOpaque()
                let copyState = copyfile_state_alloc()
                defer { copyfile_state_free(copyState) }
                copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
                copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CTX), context)
                // DATA alone: contents, not metadata (no xattrs, no modes).
                let flags = copyfile_flags_t(COPYFILE_RECURSIVE | COPYFILE_DATA)
                let result = copyfile(source.path, destination.path, copyState, flags)
                let copyErrno = errno
                withExtendedLifetime(state) {}
                if state.isCancelled { throw CancellationError() }
                guard result == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: destination.path,
                        NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: copyErrno) ?? .EIO),
                    ])
                }
                for failure in state.directoryFailures.prefix(3) {
                    let sides = "From: \(describe(failure.source)). Its folder: \(describe((failure.destination as NSString).deletingLastPathComponent))"
                    logger.error("Couldn't make \(failure.destination) (\(String(cString: strerror(failure.errno)))). \(sides)")
                }
                if state.directoryFailures.count > 3 { logger.error("…and \(state.directoryFailures.count - 3) more folders") }
                try copyAgain(state.failures)
            }
        } onCancel: {
            state.cancel()
        }
        try makeOwnerWritable(destination)
    }

    /// The files the recursive copy couldn't copy, copied again one at a
    /// time. copyfile goes on past a file it can't read, leaving it out and
    /// still succeeding, and a disc image's read now and then fails: Sea of
    /// Darkness's installer then stopped at the missing file (error 2) as
    /// though the disc were broken. A file that fails again fails the copy.
    private static func copyAgain(_ failures: [(source: String, destination: String, errno: Int32)]) throws {
        for failure in failures {
            logger.warning("Copying \(failure.source) failed (\(String(cString: strerror(failure.errno)))): copying it again")
            var lastErrno = failure.errno
            var copied = false
            for _ in 0..<3 where !copied {
                if copyfile(failure.source, failure.destination, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_UNLINK)) == 0 {
                    copied = true
                } else {
                    lastErrno = errno
                }
            }
            guard copied else {
                // What a "not permitted" needs to be told apart: each side's
                // modes, flags and ACL, and its folder's.
                let sides = "From: \(describe(failure.source)); its folder: \(describe((failure.source as NSString).deletingLastPathComponent)). "
                    + "To: \(describe(failure.destination)); its folder: \(describe((failure.destination as NSString).deletingLastPathComponent))"
                logger.error("Copying \(failure.source) failed again (\(String(cString: strerror(lastErrno)))). \(sides)")
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSFilePathErrorKey: failure.source,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: lastErrno) ?? .EIO),
                ])
            }
        }
    }

    /// A path's mode, owner, flags and whether it has an ACL, for the log:
    /// `drwxr-xr-x 501:20 flags=uchg acl`, or that it isn't there.
    static func describe(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "\(path) (\(String(cString: strerror(errno))))" }
        let mode = String(info.st_mode & 0o7777, radix: 8)
        let kind = info.st_mode & S_IFMT == S_IFDIR ? "dir" : info.st_mode & S_IFMT == S_IFLNK ? "link" : "file"
        var flags: [String] = []
        if info.st_flags & UInt32(UF_IMMUTABLE) != 0 { flags.append("uchg") }
        if info.st_flags & UInt32(SF_IMMUTABLE) != 0 { flags.append("schg") }
        if info.st_flags & UInt32(UF_APPEND) != 0 { flags.append("uappnd") }
        if info.st_flags & UInt32(UF_HIDDEN) != 0 { flags.append("hidden") }
        let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED)
        if acl != nil { acl_free(UnsafeMutableRawPointer(acl)) }
        return "\(kind) \(mode) \(info.st_uid):\(info.st_gid)\(flags.isEmpty ? "" : " flags=\(flags.joined(separator: ","))")\(acl != nil ? " acl" : "")"
    }

    /// Directories copied without their modes can still come out without
    /// write permission for the owner on some file systems: make sure.
    private static func makeOwnerWritable(_ root: URL) throws {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in walker {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let mode = attributes[.posixPermissions] as? Int, mode & 0o200 == 0 {
                try fileManager.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: url.path)
            }
        }
    }

    /// What the copy's C callback reaches through its context pointer.
    private final class CopyState: Sendable {
        public let total: Int64?
        let progress: @Sendable (Progress) -> Void
        private let state = Mutex((cancelled: false, finishedFiles: Int64(0), current: Int64(0), lastReport: ContinuousClock.Instant.now))
        private let failed = Mutex<[(source: String, destination: String, errno: Int32)]>([])

        private let failedDirectories = Mutex<[(source: String, destination: String, errno: Int32)]>([])

        /// The folders the copy couldn't make, with why.
        var directoryFailures: [(source: String, destination: String, errno: Int32)] { failedDirectories.withLock { $0 } }
        func failDirectory(source: String, destination: String, errno: Int32) {
            failedDirectories.withLock { $0.append((source, destination, errno)) }
        }

        /// The files the copy went past, with why.
        var failures: [(source: String, destination: String, errno: Int32)] { failed.withLock { $0 } }
        func fail(source: String, destination: String, errno: Int32) {
            failed.withLock { $0.append((source, destination, errno)) }
        }

        init(total: Int64?, progress: @escaping @Sendable (Progress) -> Void) {
            self.total = total
            self.progress = progress
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }
        func cancel() { state.withLock { $0.cancelled = true } }

        /// The file being copied has got to `bytes`; `finished` once it's done.
        func update(bytes: Int64, finished: Bool) {
            let report: Progress? = state.withLock { state in
                if finished {
                    state.finishedFiles += bytes
                    state.current = 0
                } else {
                    state.current = bytes
                }
                let now = ContinuousClock.Instant.now
                guard now - state.lastReport > .milliseconds(250) else { return nil }
                state.lastReport = now
                return Progress(copied: state.finishedFiles + state.current, total: total)
            }
            if let report { progress(report) }
        }
    }

    /// copyfile's progress callback: a C function, so it reaches the copy's
    /// state through `context`. Quitting is how a cancelled copy stops.
    private static let copyCallback: copyfile_callback_t = { what, stage, copyState, source, destination, context in
        guard let context else { return COPYFILE_CONTINUE }
        let state = Unmanaged<CopyState>.fromOpaque(context).takeUnretainedValue()
        if state.isCancelled { return COPYFILE_QUIT }
        // Going on past a file it can't copy leaves it out: noted, to copy
        // again once the rest is done (`copyAgain`).
        if stage == COPYFILE_ERR, what == COPYFILE_RECURSE_FILE || what == COPYFILE_COPY_DATA, let source, let destination {
            state.fail(source: String(cString: source), destination: String(cString: destination), errno: errno)
            return COPYFILE_SKIP
        }
        // A folder it couldn't make leaves out everything in it: noted, so
        // the log says why.
        if stage == COPYFILE_ERR, what == COPYFILE_RECURSE_DIR || what == COPYFILE_RECURSE_DIR_CLEANUP, let source, let destination {
            state.failDirectory(source: String(cString: source), destination: String(cString: destination), errno: errno)
        }
        if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS || what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
            var copied: off_t = 0
            copyfile_state_get(copyState, UInt32(COPYFILE_STATE_COPIED), &copied)
            state.update(bytes: Int64(copied), finished: what == COPYFILE_RECURSE_FILE)
        }
        return COPYFILE_CONTINUE
    }
}
