//
//  Blocking.swift
//  ProcessKit
//
//  Crossing between blocking code and async code, in both directions.
//
//  `run` takes blocking work off the calling thread. Second Chance's build
//  runs on the main actor, as everything in that target does by default, so
//  a subprocess waited for there, or a large copy or removal, stops the
//  window responding until it's done; `MainThreadWatchdog` logs when that
//  happens.
//
//  `wait` goes the other way: it lets code on a plain thread — the wrapp's
//  `main()` and its GCD queues — call async code and wait for the answer.

import Foundation
import WrappLogging

nonisolated public enum Blocking {
    /// Run `work` on a background thread and wait for it there, leaving the
    /// calling thread (usually the main one) free.
    ///
    /// On a GCD thread, not in a task: Swift concurrency's pool has about
    /// one thread per core, and blocking one of them for the length of a
    /// `cp` of the engine or a `codesign` (seconds to minutes, several at
    /// once when builds run side by side) would starve every other task,
    /// the bus and cancellation included. GCD makes more threads as they
    /// block.
    /// The caller's build goes with it (`LogContext.build`), which a GCD
    /// thread wouldn't otherwise have, so what `work` logs is still that
    /// build's.
    public static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let build = LogContext.build
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try LogContext.$build.withValue(build) { try work() } })
            }
        }
    }

    public static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        let build = LogContext.build
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: LogContext.$build.withValue(build) { work() })
            }
        }
    }

    /// Run async `work` and block this thread until it finishes.
    ///
    /// Only from a thread that isn't one of Swift concurrency's — never
    /// inside an async function, where blocking a pool thread can starve the
    /// very task being waited for — and only for work that doesn't need the
    /// thread it blocks: from the main thread, nothing it waits on may need
    /// the main actor.
    @discardableResult
    public static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T?>(nil)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        guard let value = box.value else { preconditionFailure("the work finished without a value") }
        return value
    }

    @discardableResult
    public static func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        try wait { () async -> Result<T, Error> in
            do { return .success(try await work()) } catch { return .failure(error) }
        }.get()
    }

    /// Written once by the task, read once after the semaphore says it has
    /// been, so never at the same time.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}
