//
//  LogContext.swift
//  WrappLogging
//
//  Which stage of the run, and which build, the log is in.

import Foundation
import Logging
import Synchronization

/// Which stage of the run the log is in, so a summary can look back to
/// where the failing stage began.
///
/// A wrapp build binds a `BuildLogContext` for its whole run (`$build`), so
/// its entries carry its id and its own stage even while another build in
/// the same process (the integration tests run them side by side) is in a
/// different one. Outside a build there is just the process's stage.
nonisolated public enum LogContext {
    private static let lock = NSLock()
    // Both guarded by `lock`.
    nonisolated(unsafe) private static var _stage: String?
    nonisolated(unsafe) private static var _stageStart: UInt64 = 0

    /// The build the current task is working for, if any. Work that leaves
    /// the task — a detached task, a dispatch queue, a pipe's reader — loses
    /// it unless it is carried across (`Blocking.run` and
    /// `ProcessLineLogger` do).
    @TaskLocal public static var build: BuildLogContext?

    /// Mark the start of a stage. Repeating the current stage keeps its start.
    public static func enterStage(_ name: String) {
        let start = LogStore.shared.nextSequence
        build?.enterStage(name, start: start)
        lock.withLock {
            guard _stage != name else { return }
            _stage = name
            _stageStart = start
        }
    }

    /// Leave the stage, at the start of a new run of work in the same
    /// process (another build), so a failure before its first stage isn't
    /// put in the last stage of the one before.
    public static func clearStage() {
        let start = LogStore.shared.nextSequence
        build?.clearStage(start: start)
        lock.withLock {
            _stage = nil
            _stageStart = start
        }
    }

    /// The build's stage when there is one, else the process's.
    public static var stage: (name: String?, start: UInt64) {
        if let build { return build.stage }
        return lock.withLock { (_stage, _stageStart) }
    }
}

/// One wrapp build's part of the log: an id its entries carry, and its stage.
nonisolated public final class BuildLogContext: Sendable {
    public let id: String
    private let state: Mutex<(stage: String?, start: UInt64)>

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.id = id
        state = Mutex((nil, LogStore.shared.nextSequence))
    }

    var stage: (name: String?, start: UInt64) {
        state.withLock { ($0.stage, $0.start) }
    }

    func enterStage(_ name: String, start: UInt64) {
        state.withLock {
            guard $0.stage != name else { return }
            $0 = (name, start)
        }
    }

    func clearStage(start: UInt64) {
        state.withLock { $0 = (nil, start) }
    }
}
