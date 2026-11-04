//
//  OrderedEmitter.swift
//  WrappBuilder
//
//  Events handed on in the order they were emitted.

import Foundation

/// An emitter whose events reach `handle` one at a time, in the order they
/// were emitted, whichever thread emitted them: they go onto one stream that
/// a single task drains, never through a `Task` of their own, so the event
/// contract's order holds. `finish` waits for every event to be handled.
public nonisolated final class OrderedEmitter: EventEmitter {
    private let continuation: AsyncStream<BuildEvent>.Continuation
    private let drain: Task<Void, Never>

    public init(_ handle: @escaping @Sendable (BuildEvent) async -> Void) {
        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        self.continuation = continuation
        drain = Task {
            for await event in stream { await handle(event) }
        }
    }

    public func emit(_ event: BuildEvent) { continuation.yield(event) }

    /// No more events: wait until every one emitted has been handled.
    public func finish() async {
        continuation.finish()
        await drain.value
    }
}
