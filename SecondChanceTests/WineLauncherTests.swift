//
//  WineLauncherTests.swift
//  SecondChanceTests
//
//  Running Wine programs through the one launcher (WineProcess.swift): how
//  each ending is reported, what a timeout or cancelling stops, and what the
//  program is given. Wine is a pair of shell scripts (`FakeWine`).

import Foundation
import Testing
@testable import SecondChance

@Suite("Wine launcher")
struct WineLauncherTests {
    @Test("A clean exit passes, and any other exit code throws it")
    func exitCodes() async throws {
        let passes = try FakeWine(wine: "exit 0")
        defer { passes.remove() }
        try await passes.wine.run(.program("setup.exe"))

        let fails = try FakeWine(wine: "exit 3")
        defer { fails.remove() }
        await #expect(throws: WineError.executionFailed(exitCode: 3)) {
            try await fails.wine.run(.program("setup.exe"))
        }
    }

    @Test("A program killed by a signal says which")
    func signal() async throws {
        let fake = try FakeWine(wine: "kill -9 $$")
        defer { fake.remove() }
        await #expect(throws: WineError.terminatedBySignal(SIGKILL)) {
            try await fake.wine.run(.program("setup.exe"))
        }
    }

    @Test("A timeout stops the Wine session, unless told to stop only the program")
    func timeoutStops() async throws {
        let session = try FakeWine(wine: "sleep 30")
        defer { session.remove() }
        await #expect(throws: WineError.timedOut(seconds: 0.5)) {
            try await session.wine.run(.program("setup.exe"), timeout: 0.5)
        }
        #expect(session.recorded("wineserver") == ["[-k]"])

        let program = try FakeWine(wine: "sleep 30")
        defer { program.remove() }
        await #expect(throws: WineError.timedOut(seconds: 0.5)) {
            try await program.wine.run(.program("setup.exe"), timeout: 0.5, onTimeout: .stopProgram)
        }
        #expect(program.recorded("wineserver").isEmpty)
    }

    @Test("Cancelling the task stops the program and its Wine session")
    func cancelStopsSession() async throws {
        let fake = try FakeWine(wine: "sleep 30")
        defer { fake.remove() }
        let run = Task { try await fake.wine.run(.program("setup.exe")) }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(fake.recorded("wineserver") == ["[-k]"])
    }

    @Test("Output is captured from stdout and stderr together")
    func output() async throws {
        let fake = try FakeWine(wine: "echo out; echo err >&2")
        defer { fake.remove() }
        let text = try await fake.wine.output(of: .wine(["reg", "query", #"HKLM\X"#]))
        #expect(text.contains("out"))
        #expect(text.contains("err"))
    }

    @Test("Captured output that says there's no display still fails")
    func outputNoDisplay() async throws {
        let fake = try FakeWine(wine: "echo '0428:err:winediag:nodrv_CreateWindow no driver could be loaded' >&2")
        defer { fake.remove() }
        await #expect(throws: WineError.noDisplay) {
            _ = try await fake.wine.output(of: .wine(["reg", "query", #"HKLM\X"#]))
        }
    }

    @Test("Arguments reach the program exactly, quotes and dollars included")
    func argumentsUnchanged() async throws {
        let fake = try FakeWine()
        defer { fake.remove() }
        try await fake.wine.run(.start("/tmp/Disc \"1\"/setup.exe", [#"$HOME `id` it's"#]))
        #expect(fake.recorded("wine") == [#"[start] [/wait] [/unix] [/tmp/Disc "1"/setup.exe] [$HOME `id` it's]"#])
    }

    @Test("A program's stdin is /dev/null")
    func stdinIsNull() async throws {
        let fake = try FakeWine(wine: #"[ "$(stat -L -f %r /dev/fd/0)" = "$(stat -f %r /dev/null)" ] || exit 5"#)
        defer { fake.remove() }
        try await fake.wine.run(.program("setup.exe"), timeout: 10)
    }

    @Test("A started program's lines are seen, and its ending waited for")
    func startAndWait() async throws {
        let fake = try FakeWine(wine: "echo first; echo second; exit 4")
        defer { fake.remove() }
        let lines = SeenLines()
        let process = try fake.wine.start(.program("steam.exe", ["-silent"]), output: .log(onLine: { lines.add($0) }))
        #expect(await process.waitUntilExit(timeout: 10) == .exited(4))
        // A second waiter is let through too.
        #expect(await process.waitUntilExit(timeout: 1) == .exited(4))
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines.all == ["first", "second"])
    }

    @Test("Waiting for a started program can time out")
    func startWaitTimesOut() async throws {
        let fake = try FakeWine(wine: "sleep 30")
        defer { fake.remove() }
        let process = try fake.wine.start(.program("game.exe"))
        defer { process.kill() }
        #expect(await process.waitUntilExit(timeout: 0.2) == nil)
    }

    @Test("A command's environment is added to Wine's")
    func environment() async throws {
        let fake = try FakeWine(wine: #"[ "$QUIT_WATCH_EXE" = "Game.exe" ] && [ -n "$WINEPREFIX" ] || exit 6"#)
        defer { fake.remove() }
        try await fake.wine.run(.program("Game.exe"), environment: ["QUIT_WATCH_EXE": "Game.exe"])
    }

    @Test("Blocking.wait returns what the work returns, and rethrows what it throws")
    func blockingWait() async throws {
        let value = await Task.detached { Blocking.wait { await Task.yield(); return 42 } }.value
        #expect(value == 42)
        let thrown = await Task.detached { () -> Bool in
            do {
                try Blocking.wait { () async throws -> Int in throw WineError.noDisplay }
                return false
            } catch {
                return true
            }
        }.value
        #expect(thrown)
    }
}

/// Lines seen from another thread.
private nonisolated final class SeenLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("Wine missing from a wrapp")
struct WineNotBundledTests {
    @Test("A wrapp with no Wine says so in everyday words")
    func notBundled() async throws {
        let wrapp = FileManager.default.temporaryDirectory.appendingPathComponent("no-wine-\(UUID().uuidString).app")
        await #expect(throws: WineError.notBundled) {
            try await Wine(wrapp: wrapp).run(.program("setup.exe"))
        }
        let text = try #require(WineError.notBundled.errorDescription)
        for word in ["Wine", "wrapp", "prefix", "executable", "bundle", "/"] {
            #expect(!text.contains(word), "says \"\(word)\"")
        }
    }
}
