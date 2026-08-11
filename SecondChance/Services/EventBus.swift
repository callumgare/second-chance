//
//  EventBus.swift
//  SecondChance
//
//  A generic, typed event bus. Subscribers receive events in publish order,
//  serialized by the actor's mailbox. Designed as the single delivery mechanism
//  for structured (typed) events across the app.
//
//  Note: this is deliberately NOT used for log text. Text logging goes directly
//  to os.Logger. The bus carries typed events that tests and UI can assert on.

import Foundation

/// A generic event bus. Events are delivered to all subscribers in publish
/// order, serialized via the actor's mailbox.
///
/// Use a concrete `Event` type (e.g. `AppEvent`) and obtain a shared instance
/// via `EventBus.app` or construct a fresh one for test isolation.
actor EventBus<Event> {
    /// A subscriber handle. Store it to unsubscribe later.
    struct Token: Hashable {
        let id: UUID
    }

    private var subscribers: [UUID: @Sendable (Event) async -> Void] = [:]

    init() {}

    /// Register a subscriber. Returns a token that can be used to unsubscribe.
    /// The handler is invoked for every subsequently published event, in publish
    /// order, on the bus's serialization context.
    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (Event) async -> Void) -> Token {
        let id = UUID()
        subscribers[id] = handler
        return Token(id: id)
    }

    /// Remove a subscriber. Safe to call with an already-removed token.
    func unsubscribe(_ token: Token) {
        subscribers[token.id] = nil
    }

    /// Remove all subscribers.
    func unsubscribeAll() {
        subscribers.removeAll()
    }

    /// Deliver an event to every subscriber. Publishes are processed one at a
    /// time, so subscribers observe events in the order they were published.
    ///
    /// Note: subscribers are awaited sequentially. A slow subscriber delays
    /// subsequent subscribers and subsequent publishes. For non-critical sinks
    /// (e.g. file writes) prefer detaching work inside the handler.
    func publish(_ event: Event) async {
        for handler in subscribers.values {
            await handler(event)
        }
    }
}
