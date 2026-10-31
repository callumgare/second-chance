//
//  WineServerTests.swift
//  SecondChanceTests
//
//  Waiting for and ending a prefix's Wine session through `wine.server`. The
//  fake wineserver keeps its "session" as a marker file beside the prefix:
//  -w waits while it's there, -k and -k9 remove it (-k only unless told to
//  ignore SIGTERM), and -k0 says whether it's there.

import Foundation
import Testing
@testable import SecondChance

@Suite("Wine server")
struct WineServerTests {
    /// A fake Wine with a session running, unless `running` is false.
    private static func fake(running: Bool = true, ignoresTerm: Bool = false) throws -> FakeWine {
        let fake = try FakeWine(wineserver: """
            session="$WINEPREFIX-session"
            case "$1" in
              -w) while [ -f "$session" ]; do sleep 0.05; done ;;
              -k0) [ -f "$session" ] || exit 1 ;;
              -k) [ -f "$WINEPREFIX-ignores-term" ] || rm -f "$session" ;;
              -k9) rm -f "$session" ;;
            esac
            """)
        let prefix = fake.wine.prefix.path
        if running { FileManager.default.createFile(atPath: prefix + "-session", contents: nil) }
        if ignoresTerm { FileManager.default.createFile(atPath: prefix + "-ignores-term", contents: nil) }
        return fake
    }

    private static func endSession(of fake: FakeWine) {
        try? FileManager.default.removeItem(atPath: fake.wine.prefix.path + "-session")
    }

    @Test("Whether the session is running")
    func isRunning() async throws {
        let running = try Self.fake()
        defer { running.remove() }
        #expect(await running.wine.server.isRunning)

        let stopped = try Self.fake(running: false)
        defer { stopped.remove() }
        #expect(await !stopped.wine.server.isRunning)
    }

    @Test("Shutting down waits for a session that ends by itself, and goes no further")
    func shutDownGracefully() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        Task {
            try await Task.sleep(for: .milliseconds(300))
            Self.endSession(of: fake)
        }
        #expect(await fake.wine.server.shutDown(gracePeriod: 10))
        #expect(fake.recorded("wineserver") == ["[-w]"])
    }

    @Test("Shutting down stops a session that outlives its grace period")
    func shutDownStops() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        #expect(await fake.wine.server.shutDown(gracePeriod: 0.3))
        // The waits aren't counted: one stopped at 0.3 s may not have got as
        // far as recording itself.
        #expect(fake.recorded("wineserver").filter { $0 != "[-w]" } == ["[-k]"])
    }

    @Test("Shutting down kills a session that ignores being stopped")
    func shutDownKills() async throws {
        let fake = try Self.fake(ignoresTerm: true)
        defer { fake.remove() }
        #expect(await fake.wine.server.shutDown(gracePeriod: 0.3, stopPeriod: 0.5))
        #expect(fake.recorded("wineserver").filter { $0 != "[-w]" } == ["[-k]", "[-k9]"])
    }

    @Test("Waiting gives up at its timeout, leaving the session running")
    func waitTimesOut() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let started = Date()
        #expect(await !fake.wine.server.waitUntilStopped(timeout: 0.3))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await fake.wine.server.isRunning)
    }

    @Test("onStop calls back once the session ends")
    func onStop() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let calls = Counter()
        let waiter = fake.wine.server.onStop { calls.increment() }
        #expect(waiter != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.value == 0)
        Self.endSession(of: fake)
        let deadline = Date().addingTimeInterval(10)
        while calls.value == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(calls.value == 1)
    }

    @Test("onStop doesn't call back once its waiter is terminated")
    func onStopCancelled() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let calls = Counter()
        let waiter = try #require(fake.wine.server.onStop { calls.increment() })
        try await Task.sleep(for: .milliseconds(200))
        waiter.terminate()
        Self.endSession(of: fake)
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls.value == 0)
    }

    @Test("Without a bundled Wine there's no session to wait for or stop")
    func noWine() async {
        let server = Wine(wrapp: URL(fileURLWithPath: "/nonexistent/ScummVM Game.app")).server
        #expect(await !server.isRunning)
        #expect(await server.waitUntilStopped(timeout: 1))
        #expect(await server.shutDown())
        #expect(server.onStop {} == nil)
        await server.kill()
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
