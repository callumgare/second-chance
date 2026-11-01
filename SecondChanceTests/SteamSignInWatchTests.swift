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

    @Test("A write to Steam's logs is activity, and none leaves the last one standing")
    func logActivity() async throws {
        let client = try await startedClient()
        var watch = SteamSignInWatch(client: client)
        let started = watch.lastLogActivity
        let later = started.addingTimeInterval(10)
        _ = watch.check(now: later)
        #expect(watch.lastLogActivity == started)
        client.logWrite = Date()
        _ = watch.check(now: later)
        #expect(watch.lastLogActivity == later)
        _ = watch.check(now: later.addingTimeInterval(10))
        #expect(watch.lastLogActivity == later)
    }

    @Test("Quiet logs warn at half the limit, a write takes the warning back, and the limit is stuck")
    func quietActiveStuck() async throws {
        let client = try await startedClient()
        client.login = .pending
        var watch = SteamSignInWatch(client: client, quietLimit: 100, isHeavilyLoaded: { false })
        let start = watch.lastLogActivity
        #expect(watch.check(now: start.addingTimeInterval(49)).isEmpty)
        #expect(watch.check(now: start.addingTimeInterval(50)) == [.quiet(stuckAt: start.addingTimeInterval(100))])
        client.logWrite = Date()
        let written = start.addingTimeInterval(60)
        #expect(watch.check(now: written) == [.active])
        #expect(watch.check(now: written.addingTimeInterval(50)) == [.quiet(stuckAt: written.addingTimeInterval(100))])
        #expect(watch.check(now: written.addingTimeInterval(100)) == [.stuck(quietFor: 100)])
        #expect(watch.check(now: written.addingTimeInterval(200)).isEmpty)
    }

    @Test("On a heavily loaded Mac, Steam gets three times as long to be quiet")
    func quietUnderLoad() async throws {
        let client = try await startedClient()
        client.login = .pending
        var watch = SteamSignInWatch(client: client, quietLimit: 100, isHeavilyLoaded: { true })
        let start = watch.lastLogActivity
        #expect(watch.check(now: start.addingTimeInterval(100)).isEmpty)
        #expect(watch.check(now: start.addingTimeInterval(150)) == [.quiet(stuckAt: start.addingTimeInterval(300))])
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

@Suite("What to do while Steam is slow or stuck signing in")
struct SteamStallPolicyTests {
    let stuckAt = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("Slow says when Steam starts again, a write takes it back, and stuck starts Steam again")
    func firstStall() {
        var policy = SteamStallPolicy(canOfferFreshSignIn: true)
        #expect(policy.handle(.quiet(stuckAt: stuckAt)) == [.notice(.slow(restartAt: stuckAt))])
        #expect(policy.handle(.active) == [.notice(nil)])
        _ = policy.handle(.quiet(stuckAt: stuckAt))
        #expect(policy.handle(.stuck(quietFor: 240)) == [.notice(nil), .restart])
    }

    @Test("Stuck again, Steam is left running with the offer to sign in afresh, which goes once it signs in")
    func secondStall() {
        var policy = SteamStallPolicy(canOfferFreshSignIn: true)
        _ = policy.handle(.stuck(quietFor: 240))
        // No countdown: Steam won't be started again by itself.
        #expect(policy.handle(.quiet(stuckAt: stuckAt)) == [.notice(.slow(restartAt: nil))])
        #expect(policy.handle(.stuck(quietFor: 240)) == [.notice(.stuck)])
        #expect(policy.handle(.active).isEmpty)
        #expect(policy.handle(.signedIn) == [.notice(nil)])
    }

    @Test("Stuck after signing in afresh, or a second time with nobody to offer it to, fails")
    func gives_up() {
        var policy = SteamStallPolicy(canOfferFreshSignIn: true)
        _ = policy.handle(.stuck(quietFor: 240))
        _ = policy.handle(.stuck(quietFor: 240))
        #expect(policy.signingInAfresh() == [.notice(nil)])
        #expect(policy.handle(.stuck(quietFor: 240)) == [.fail])

        var headless = SteamStallPolicy(canOfferFreshSignIn: false)
        _ = headless.handle(.stuck(quietFor: 240))
        #expect(headless.handle(.stuck(quietFor: 240)) == [.fail])
    }

    @Test("The notice counts down to Steam starting again")
    func countdown() {
        let notice = SteamSignInNotice.slow(restartAt: stuckAt)
        #expect(notice.detail(now: stuckAt.addingTimeInterval(-100)).contains("in 1m 40s"))
        #expect(notice.detail(now: stuckAt.addingTimeInterval(-9.5)).contains("in 10s"))
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
