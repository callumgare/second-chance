//
//  AsyncMutex.swift
//  SecondChance
//
//  A lock for async code: one holder at a time, the rest waiting their turn
//  without blocking a thread.

import Foundation

/// One holder at a time, first come first served.
actor AsyncMutex {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Run `body` once the lock is free, holding it until `body` ends.
    nonisolated func withLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
