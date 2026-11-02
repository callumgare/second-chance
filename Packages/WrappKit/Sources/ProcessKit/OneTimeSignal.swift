//
//  OneTimeSignal.swift
//  ProcessKit
//
//  Something that happens once, for async code to wait on.

import Foundation
import Synchronization
import WrappLogging

/// Something that happens once — the player confirming the save warning, a
/// process exiting — signalled from any thread and awaited from async code,
/// in place of a semaphore a thread would block on. Signalling again does
/// nothing; a wait that starts after the signal returns at once.
nonisolated public final class OneTimeSignal: Sendable {
    private struct State {
        var signalled = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    public init() {}

    public var isSignalled: Bool { state.withLock { $0.signalled } }

    public func signal() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.signalled else { return [] }
            state.signalled = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Until it is signalled, or the task is cancelled.
    public func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now = state.withLock { state -> Bool in
                    if state.signalled || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// Until it is signalled or `timeout` has passed: whether it was signalled.
    public func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        return isSignalled
    }
}
