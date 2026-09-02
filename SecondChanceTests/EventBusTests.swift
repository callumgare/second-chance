//
//  EventBusTests.swift
//  SecondChanceTests
//
//  Unit tests for the generic EventBus actor. Verifies subscribe/publish
//  ordering, unsubscribe, and multi-subscriber fan-out — the guarantees the
//  per-game integration tests and UI rely on.

import Testing
import Foundation
@testable import SecondChance

@Suite("EventBus")
struct EventBusTests {

    // MARK: - Delivery & ordering

    @Test("Subscribers receive published events")
    func subscribersReceiveEvents() async {
        let bus = EventBus<String>()
        let collector = EventCollector<String>()
        let token = await bus.subscribe { await collector.append($0) }

        await bus.publish("a")
        await bus.publish("b")

        let events = await collector.events
        #expect(events == ["a", "b"])
        _ = token
    }

    @Test("Events are delivered in publish order")
    func eventsDeliveredInOrder() async {
        let bus = EventBus<Int>()
        let collector = EventCollector<Int>()
        _ = await bus.subscribe { await collector.append($0) }

        // Publish many events; verify they arrive in the same order.
        for i in 0..<100 {
            await bus.publish(i)
        }

        let events = await collector.events
        #expect(events == Array(0..<100))
    }

    // MARK: - Multiple subscribers

    @Test("Multiple subscribers each receive all events")
    func multipleSubscribers() async {
        let bus = EventBus<String>()
        let collector1 = EventCollector<String>()
        let collector2 = EventCollector<String>()

        _ = await bus.subscribe { await collector1.append($0) }
        _ = await bus.subscribe { await collector2.append($0) }

        await bus.publish("x")
        await bus.publish("y")

        let e1 = await collector1.events
        let e2 = await collector2.events
        #expect(e1 == ["x", "y"])
        #expect(e2 == ["x", "y"])
    }

    // MARK: - Unsubscribe

    @Test("Unsubscribed handlers stop receiving events")
    func unsubscribeStopsDelivery() async {
        let bus = EventBus<String>()
        let collector = EventCollector<String>()
        let token = await bus.subscribe { await collector.append($0) }

        await bus.publish("before")
        await bus.unsubscribe(token)
        await bus.publish("after")

        let events = await collector.events
        #expect(events == ["before"])
    }

    @Test("Unsubscribing an unknown token is safe")
    func unsubscribeUnknownTokenSafe() async {
        let bus = EventBus<String>()
        let bogusToken = EventBus<String>.Token(id: UUID())

        // Should not throw or crash.
        await bus.unsubscribe(bogusToken)
    }

    @Test("unsubscribeAll removes every subscriber")
    func unsubscribeAll() async {
        let bus = EventBus<String>()
        let collector = EventCollector<String>()
        _ = await bus.subscribe { await collector.append($0) }
        _ = await bus.subscribe { await collector.append($0) }

        await bus.unsubscribeAll()
        await bus.publish("nobody-home")

        let events = await collector.events
        #expect(events.isEmpty)
    }

    // MARK: - AppEvent convenience

    @Test("publishWrappBuild wraps in .installation case")
    func publishWrappBuildWraps() async {
        let bus = EventBus<AppEvent>()
        let collector = EventCollector<AppEvent>()
        _ = await bus.subscribe { await collector.append($0) }

        let gameInfo = GameInfo(id: "test", title: "Test Game")
        await bus.publishWrappBuild(.gameDetected(gameInfo))

        let events = await collector.events
        #expect(events.count == 1)
        guard case .wrappBuild(.gameDetected(let info)) = events.first else {
            Issue.record("Expected .wrappBuild(.gameDetected) event")
            return
        }
        #expect(info.id == "test")
    }

    @Test("Fresh bus instance is isolated from the shared app bus")
    func freshBusIsIsolated() async {
        // Publishing to a fresh instance should not reach subscribers of the
        // shared app bus. (We subscribe to the app bus and verify no events.)
        let collector = EventCollector<AppEvent>()
        let token = await EventBus.app.subscribe { await collector.append($0) }

        let isolated = EventBus<AppEvent>()
        await isolated.publishWrappBuild(.completed(wrappPath: URL(fileURLWithPath: "/tmp")))

        let events = await collector.events
        #expect(events.isEmpty, "Isolated bus events must not leak to the shared app bus")
        await EventBus.app.unsubscribe(token)
    }
}

// MARK: - Test helper

/// A tiny actor that collects events into an array. Thread-safe by virtue of
/// actor isolation; used in tests to capture what the bus delivered.
actor EventCollector<T> {
    private(set) var events: [T] = []
    func append(_ event: T) { events.append(event) }
}
