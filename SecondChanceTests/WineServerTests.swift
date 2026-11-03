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
@testable import ProcessKit
@testable import SecondChance
@testable import SecondChanceKit
@testable import WineKit

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
        // Still running as the session ends, so it isn't stopped for being idle.
        let program = try WineLeftoverTests.startProgram(fake, in: fake.wine.prefix)
        defer { program.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        Task {
            try await Task.sleep(for: .milliseconds(300))
            Self.endSession(of: fake)
        }
        let steps = StepRecorder()
        #expect(await fake.wine.server.shutDown(gracePeriod: 10) { steps.append($0) })
        #expect(fake.recorded("wineserver") == ["[-w]"])
        #expect(steps.values == [.waiting])
    }

    @Test("Shutting down stops a server left lingering once its programs end, without waiting out the grace period")
    func shutDownIdle() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let program = try WineLeftoverTests.startProgram(fake, in: fake.wine.prefix)
        defer { program.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        Task {
            try await Task.sleep(for: .milliseconds(300))
            program.terminate()
        }
        let started = Date()
        let steps = StepRecorder()
        #expect(await fake.wine.server.shutDown(gracePeriod: 60) { steps.append($0) })
        // Well short of the grace period; generous, as the suite runs in parallel.
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(fake.recorded("wineserver").filter { $0 != "[-w]" } == ["[-k]"])
        // Routine, so the closing window isn't told it's taking long.
        #expect(steps.values == [.waiting])
    }

    @Test("Wine's services, which linger with the server, don't keep a shutdown waiting")
    func shutDownIdleWithServices() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let program = try WineLeftoverTests.startProgram(fake, in: fake.wine.prefix)
        let service = try WineLeftoverTests.startProgram(fake, in: fake.wine.prefix, named: "services.exe")
        defer { [program, service].forEach { $0.terminate() } }
        try await Task.sleep(for: .milliseconds(200))
        Task {
            try await Task.sleep(for: .milliseconds(300))
            program.terminate()
        }
        let started = Date()
        #expect(await fake.wine.server.shutDown(gracePeriod: 60))
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(fake.recorded("wineserver").filter { $0 != "[-w]" } == ["[-k]"])
    }

    @Test("Shutting down stops a session that outlives its grace period")
    func shutDownStops() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let program = try WineLeftoverTests.startProgram(fake, in: fake.wine.prefix)
        defer { program.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        let steps = StepRecorder()
        #expect(await fake.wine.server.shutDown(gracePeriod: 0.3) { steps.append($0) })
        // The waits aren't counted: one stopped at 0.3 s may not have got as
        // far as recording itself.
        #expect(fake.recorded("wineserver").filter { $0 != "[-w]" } == ["[-k]"])
        #expect(steps.values == [.waiting, .stopping])
    }

    @Test("Shutting down kills a session that ignores being stopped")
    func shutDownKills() async throws {
        let fake = try Self.fake(ignoresTerm: true)
        defer { fake.remove() }
        let program = try WineLeftoverTests.startProgram(fake, in: fake.wine.prefix)
        defer { program.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fake.wine.server.shutDown(gracePeriod: 0.3, stopPeriod: 0.5))
        #expect(fake.recorded("wineserver").filter { $0 != "[-w]" } == ["[-k]", "[-k9]"])
    }

    @Test("Waiting gives up at its timeout, leaving the session running")
    func waitTimesOut() async throws {
        let fake = try Self.fake()
        defer { fake.remove() }
        let started = Date()
        #expect(await !fake.wine.server.waitUntilStopped(timeout: 0.3))
        // Well short of never; generous, as the suite runs in parallel.
        #expect(Date().timeIntervalSince(started) < 15)
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

private nonisolated final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [WineServer.ShutdownStep] = []

    func append(_ step: WineServer.ShutdownStep) { lock.withLock { steps.append(step) } }
    var values: [WineServer.ShutdownStep] { lock.withLock { steps } }
}

/// A prefix's programs found by the folder they work in, as they are when
/// `wineserver -k9` has left them running with no server.
@Suite("Wine programs left behind")
struct WineLeftoverTests {
    /// A stand-in Wine program: `sleep`, started through a link in the fake
    /// Wine's bin, which `ps` names it by (so `ProcessList.isWine` counts it),
    /// working in `directory`. A link, as a copy of a system program is
    /// killed as it starts.
    static func startProgram(_ fake: FakeWine, in directory: URL, named name: String = "sleep") throws -> Process {
        let program = fake.wrapp.appendingPathComponent("Contents/SharedSupport/wine/bin/\(name)")
        if !FileManager.default.fileExists(atPath: program.path) {
            try FileManager.default.createSymbolicLink(at: program, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = program
        process.arguments = ["60"]
        process.currentDirectoryURL = directory
        try process.run()
        return process
    }

    @Test("A process's working folder is read with symlinks resolved")
    func workingDirectory() throws {
        let cwd = try #require(ProcessList.workingDirectory(of: getpid()))
        #expect(cwd == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
            || cwd.hasPrefix("/private") && cwd.hasSuffix(FileManager.default.currentDirectoryPath))
    }

    @Test("Programs working in the prefix, or beside it, are its; others are elsewhere")
    func programsByFolder() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        let other = try FakeWine()
        defer { other.remove() }
        let inPrefix = try Self.startProgram(fake, in: fake.wine.prefix.appendingPathComponent("drive_c/Game"))
        let beside = try Self.startProgram(fake, in: fake.wine.prefix.deletingLastPathComponent())
        let elsewhere = try Self.startProgram(other, in: other.wine.prefix)
        defer { [inPrefix, beside, elsewhere].forEach { $0.terminate() } }
        try await Task.sleep(for: .milliseconds(200))

        let server = fake.wine.server
        let found = Set(server.programs().map(\.pid))
        #expect(found == [inPrefix.processIdentifier, beside.processIdentifier])
        #expect(!server.isElsewhere(inPrefix.processIdentifier))
        #expect(server.isElsewhere(elsewhere.processIdentifier))
        // Gone, or never there: can't be told, so not counted as elsewhere.
        #expect(!server.isElsewhere(0))
    }

    @Test("A kill leaves none of the prefix's programs, and only the prefix's")
    func killLeavesNothing() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        let other = try FakeWine()
        defer { other.remove() }
        let left = try Self.startProgram(fake, in: fake.wine.prefix)
        let elsewhere = try Self.startProgram(other, in: other.wine.prefix)
        defer { elsewhere.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        await fake.wine.server.kill()
        left.waitUntilExit()
        #expect(left.terminationReason == .uncaughtSignal && left.terminationStatus == SIGKILL)
        #expect(fake.recorded("wineserver") == ["[-k9]"])
        #expect(elsewhere.isRunning)
    }

    @Test("A shutdown leaves none of the prefix's programs, however Wine ended")
    func shutDownSweeps() async throws {
        // A session already over (-w returns at once), with a program left.
        let fake = try FakeWine(wineserver: "exit 0")
        defer { fake.remove() }
        let left = try Self.startProgram(fake, in: fake.wine.prefix)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fake.wine.server.shutDown())
        left.waitUntilExit()
        #expect(left.terminationStatus == SIGKILL)
    }

    @Test("A launch clears what a killed session left, but not a running session's programs")
    func clearLeftovers() async throws {
        let dead = try FakeWine(wineserver: "exit 1")
        defer { dead.remove() }
        let leftover = try Self.startProgram(dead, in: dead.wine.prefix)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await dead.wine.server.clearLeftovers() == 1)
        leftover.waitUntilExit()
        #expect(leftover.terminationStatus == SIGKILL)

        let running = try FakeWine(wineserver: "exit 0")
        defer { running.remove() }
        let program = try Self.startProgram(running, in: running.wine.prefix)
        defer { program.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await running.wine.server.clearLeftovers() == 0)
        #expect(program.isRunning)
    }
}
