//
//  SteamSignInWatchTests.swift
//  SecondChanceTests
//
//  What a build and a wrapp both see while Steam starts and signs in, and
//  how both wait for the one-Steam-at-a-time lock.

import Foundation
import Testing
@testable import SecondChanceKit

@Suite("Steam sign-in watch")
struct SteamSignInWatchTests {
    private func startedClient() async throws -> FakeSteamClient {
        let client = FakeSteamClient(wrappPath: URL(fileURLWithPath: "/tmp/SteamSignInWatchTests.app"))
        try await client.start(silent: true)
        return client
    }

    @Test("An update is followed until Steam asks for a sign-in, which is told once")
    func updateThenSignIn() async throws {
        let client = try await startedClient()
        client.updatingChecks = 2
        client.login = .needsCredentials(reason: "Invalid Password")
        var watch = SteamSignInWatch(client: client)
        #expect(watch.check() == [.startup(.updating(.downloading(doneKB: 51_200, totalKB: 102_400)))])
        let rest = (0..<4).flatMap { _ in watch.check() }
        #expect(rest.filter { $0 == .needsSignIn(reason: "Invalid Password") }.count == 1)
        #expect(watch.askedForSignIn)
        #expect(watch.check().isEmpty)
        client.login = .signedIn
        #expect(watch.check() == [.signedIn])
    }

    @Test("Steam missing from enough checks in a row has exited, and a restart starts the count again")
    func exited() async throws {
        let client = FakeSteamClient(wrappPath: URL(fileURLWithPath: "/tmp/SteamSignInWatchTests.app"))
        var watch = SteamSignInWatch(client: client, exitedChecks: 2)
        #expect(!watch.check().contains(.exited))
        #expect(watch.check().contains(.exited))
        watch.restarted()
        #expect(!watch.check().contains(.exited))
    }

    @Test("Whether Steam is running is checked no more often than asked")
    func runningCheckInterval() {
        let client = FakeSteamClient(wrappPath: URL(fileURLWithPath: "/tmp/SteamSignInWatchTests.app"))
        let start = Date()
        var watch = SteamSignInWatch(client: client, exitedChecks: 1, runningCheckInterval: 5)
        #expect(!watch.check(now: start.addingTimeInterval(1)).contains(.exited))
        // Well past 5 s: the watch starts its clock a moment after `start`.
        #expect(watch.check(now: start.addingTimeInterval(6)).contains(.exited))
    }
}

@Suite("Waiting for the Steam lock")
struct SteamLockTakingTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-lock-\(UUID().uuidString)")

    @Test("A free lock is taken without asking")
    func free() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let taking = try await SteamActiveLock.take(root: root, bundleID: "au.example.one") { _ in
            Issue.record("nobody should be asked")
            return .cancel
        }
        guard case .acquired(let lock) = taking else {
            Issue.record("the lock should be taken")
            return
        }
        lock.release()
    }

    @Test("While it's held, each answer is acted on", arguments: [
        (SteamLockHolder.Choice?.none, "held"), (.cancel, "cancelled"), (.tryAgain, "acquired"),
    ])
    func held(answer: SteamLockHolder.Choice?, outcome: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .acquired(let holding) = try SteamActiveLock.acquire(root: root, bundleID: "au.example.one") else {
            Issue.record("the first acquire should succeed")
            return
        }
        var asked = 0
        let taking = try await SteamActiveLock.take(root: root, bundleID: "au.example.two") { holder in
            asked += 1
            #expect(holder.bundleID == "au.example.one")
            // Trying again finds it free: the holder quit meanwhile.
            if answer == .tryAgain { holding.release() }
            return answer
        }
        holding.release()
        #expect(asked == 1)
        switch taking {
        case .acquired(let lock):
            #expect(outcome == "acquired")
            lock.release()
        case .cancelled:
            #expect(outcome == "cancelled")
        case .held:
            #expect(outcome == "held")
        }
    }
}
