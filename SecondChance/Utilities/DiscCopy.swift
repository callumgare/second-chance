//
//  DiscCopy.swift
//  SecondChance
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
import SecondChanceKit
import Synchronization

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.DiscCopy")

nonisolated enum DiscCopy {
    /// How far a copy has got, in bytes.
    struct Progress: Sendable {
        let copied: Int64
        let total: Int64?
    }

    /// Copy the folder `source` to `destination`, which mustn't exist yet.
    /// `progress` is called as the copy goes, from the copying thread, at
    /// most a few times a second. Throws `CancellationError` once the task is
    /// cancelled, leaving what was copied for the caller to remove.
    static func copy(from source: URL, to destination: URL, total: Int64?,
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
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSFilePathErrorKey: failure.source,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: lastErrno) ?? .EIO),
                ])
            }
        }
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
        let total: Int64?
        let progress: @Sendable (Progress) -> Void
        private let state = Mutex((cancelled: false, finishedFiles: Int64(0), current: Int64(0), lastReport: ContinuousClock.Instant.now))
        private let failed = Mutex<[(source: String, destination: String, errno: Int32)]>([])

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
        if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS || what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
            var copied: off_t = 0
            copyfile_state_get(copyState, UInt32(COPYFILE_STATE_COPIED), &copied)
            state.update(bytes: Int64(copied), finished: what == COPYFILE_RECURSE_FILE)
        }
        return COPYFILE_CONTINUE
    }
}
