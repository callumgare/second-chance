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
import SecondChanceKit
import Synchronization

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
                withExtendedLifetime(state) {}
                if state.isCancelled { throw CancellationError() }
                guard result == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: destination.path,
                        NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                    ])
                }
            }
        } onCancel: {
            state.cancel()
        }
        try makeOwnerWritable(destination)
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
    private static let copyCallback: copyfile_callback_t = { what, stage, copyState, _, _, context in
        guard let context else { return COPYFILE_CONTINUE }
        let state = Unmanaged<CopyState>.fromOpaque(context).takeUnretainedValue()
        if state.isCancelled { return COPYFILE_QUIT }
        if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS || what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
            var copied: off_t = 0
            copyfile_state_get(copyState, UInt32(COPYFILE_STATE_COPIED), &copied)
            state.update(bytes: Int64(copied), finished: what == COPYFILE_RECURSE_FILE)
        }
        return COPYFILE_CONTINUE
    }
}
