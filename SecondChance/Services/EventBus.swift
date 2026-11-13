//
//  EventBus.swift
//  SecondChance
//
//  A generic, typed event bus. Each subscriber receives events in the order
//  they were published, one at a time, through a queue of its own. Designed
//  as the single delivery mechanism for structured (typed) events across the
//  app.
//
//  Note: this is deliberately NOT used for log text. Text logging goes directly
//  through swift-log. The bus carries typed events that tests and UI can assert on.

import Foundation
import Synchronization

/// A generic event bus. Each subscriber gets every event in the order its
/// `publish` reached the bus, one at a time, and `publish` returns once
/// every subscriber has handled it.
///
/// The order holds even when publishes overlap: the actor is re-entrant, so
/// handlers awaited from inside `publish` would let a later publish's
/// handlers run between them. Instead each subscriber has a queue of its own,
/// filled synchronously on the actor — so in the order publishes arrive —
/// and drained by a task of its own.
///
/// Use a concrete `Event` type (e.g. `AppEvent`) and obtain a shared instance
/// via `EventBus.app` or construct a fresh one for test isolation.
actor EventBus<Event: Sendable> {
    /// A subscriber handle. Store it to unsubscribe later.
    struct Token: Hashable {
        let id: UUID
    }

    private struct Delivery: Sendable {
        let event: Event
        let done: Done
    }

    private struct Subscriber {
        let queue: AsyncStream<Delivery>.Continuation
        let drain: Task<Void, Never>
    }

    private var subscribers: [UUID: Subscriber] = [:]

    init() {}

    /// Register a subscriber. Returns a token that can be used to unsubscribe.
    /// The handler is invoked for every subsequently published event, in publish
    /// order, one at a time.
    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (Event) async -> Void) -> Token {
        let id = UUID()
        let (stream, queue) = AsyncStream.makeStream(of: Delivery.self)
        let drain = Task {
            for await delivery in stream {
                await EventBusDelivery.$subscriber.withValue(id) { await handler(delivery.event) }
                delivery.done.finish()
            }
        }
        subscribers[id] = Subscriber(queue: queue, drain: drain)
        return Token(id: id)
    }

    /// Remove a subscriber. Safe to call with an already-removed token.
    /// Events already queued for it are still delivered.
    func unsubscribe(_ token: Token) {
        subscribers.removeValue(forKey: token.id)?.queue.finish()
    }

    /// Remove all subscribers.
    func unsubscribeAll() {
        subscribers.values.forEach { $0.queue.finish() }
        subscribers.removeAll()
    }

    /// Deliver an event to every subscriber, and wait until each has handled
    /// it. A slow subscriber holds up this publish, but not another
    /// subscriber's handling of it.
    func publish(_ event: Event) async {
        let me = EventBusDelivery.subscriber
        var waits: [Done] = []
        for (id, subscriber) in subscribers {
            let done = Done()
            subscriber.queue.yield(Delivery(event: event, done: done))
            if id != me { waits.append(done) }
        }
        for done in waits {
            await done.wait()
        }
    }
}

/// The subscriber whose handler this task is running, if any: a handler
/// that publishes mustn't wait for its own queue, which is busy with it.
/// Outside `EventBus`, as a generic type can't hold a task-local.
nonisolated private enum EventBusDelivery {
    @TaskLocal static var subscriber: UUID?
}

/// Signalled once a subscriber has handled a delivery.
nonisolated private final class Done: Sendable {
    private let state = Mutex<(finished: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.finished { return true }
                state.waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}
