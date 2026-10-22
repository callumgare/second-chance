//
//  SteamSessionTests.swift
//  SecondChanceTests
//
//  The shared Steam sign-in, Steam's logs, and the one-wrapp-at-a-time lock.

import AppKit
import Foundation
import Testing
@testable import SecondChance

@Suite("Steam logs")
struct SteamLogsTests {
    // Lines as a real Steam wrote them, account IDs removed.
    @Test("A logon response of OK is signed in")
    func signedIn() {
        let connection = """
        [2026-10-19 19:55:36] [Logged Off, 4, 0] [U:1:…] LogOn() called; not connected yet, scheduling connection. Schedule init returned 1
        [2026-10-19 19:55:38] [Logging On, 4, 2] [U:1:…] RecvMsgClientLogOnResponse() : [U:1:…] 'OK'
        [2026-10-19 19:55:38] [Logged On, 4, 2] [U:1:…] RecvMsgClientLogOnResponse() : processing complete
        """
        #expect(SteamLogs.loginState(connectionLog: connection, loginLog: "") == .signedIn)
    }

    @Test("Waiting for credentials asks for a sign-in, with Steam's reason")
    func needsCredentials() {
        #expect(SteamLogs.loginState(connectionLog: "", loginLog: """
        [2026-10-19 20:01:58] [ None ] SetLoginState: WaitingForCredentials - OK
        """) == .needsCredentials(reason: nil))
        #expect(SteamLogs.loginState(connectionLog: "", loginLog: """
        [2026-10-19 20:03:58] [ WaitingForServerResponse ] SetLoginState: WaitingForCredentials - Invalid Password
        """) == .needsCredentials(reason: "Invalid Password"))
    }

    @Test("Nothing yet is pending; a later success wins over an earlier failure")
    func latestWins() {
        #expect(SteamLogs.loginState(connectionLog: "", loginLog: "") == .pending)
        #expect(SteamLogs.loginState(connectionLog: "", loginLog: """
        [t] SetLoginState: WaitingForCredentials - Invalid Password
        [t] [ WaitingForServerResponse ] Received logon success response
        """) == .signedIn)
    }

    @Test("An install's phases, from start to installed")
    func installPhases() {
        let lines = [
            "[2026-10-19 20:13:47] AppID 226820 state changed : Update Required,Update Queued,Update Started,",
            "[2026-10-19 20:13:48] AppID 226820 App update changed : Running Update,Preallocating,",
            "[2026-10-19 20:13:51] AppID 226820 update started : download 0/2409188976, store 0/0, reuse 0/0, delta 0/0, stage 0/2569437999 ",
            "[2026-10-19 20:13:51] AppID 226820 App update changed : Running Update,Downloading,Staging,",
            "[2026-10-19 20:15:37] AppID 226820 App update changed : Running Update,Verifying Staged,",
            "[2026-10-19 20:15:42] AppID 226820 App update changed : Running Update,Committing,",
            "[2026-10-19 20:15:44] AppID 226820 state changed : Fully Installed,Update Queued,Update Running,",
            "[2026-10-19 20:15:44] AppID 226820 App update changed : None",
            "[2026-10-19 20:15:44] AppID 226820 state changed : Fully Installed,",
            "[2026-10-19 20:15:44] AppID 226820 scheduler finished : removed from schedule (result No Error, state 0xc) ",
        ]
        func phase(after count: Int) -> SteamLogs.InstallPhase {
            SteamLogs.installPhase(appID: 226820, contentLog: lines.prefix(count).joined(separator: "\n"))
        }
        #expect(phase(after: 0) == .waiting)
        #expect(phase(after: 2) == .updating(phase: "Preallocating", bytesToDownload: nil))
        #expect(phase(after: 4) == .updating(phase: "Downloading", bytesToDownload: 2_409_188_976))
        #expect(phase(after: 5) == .updating(phase: "Verifying Staged", bytesToDownload: 2_409_188_976))
        #expect(phase(after: 7) == .updating(phase: "Committing", bytesToDownload: 2_409_188_976))
        #expect(phase(after: lines.count) == .installed)
        // Another app's lines don't count.
        #expect(SteamLogs.installPhase(appID: 615770, contentLog: lines.joined(separator: "\n")) == .waiting)
    }

    @Test("Steam's Windows line endings split into lines too")
    func crlf() {
        // "\r\n" is one Character in Swift, so splitting on "\n" alone leaves
        // the whole log as one line — which hung the first real install test.
        let content = [
            "[t] AppID 1 App update changed : Running Update,Downloading,Staging,",
            "[t] AppID 1 state changed : Fully Installed,",
        ].joined(separator: "\r\n") + "\r\n"
        #expect(SteamLogs.installPhase(appID: 1, contentLog: content) == .installed)
        let login = "[t] SetLoginState: WaitingForCredentials - Invalid Password\r\n[t] Received logon success response\r\n"
        #expect(SteamLogs.loginState(connectionLog: "", loginLog: login) == .signedIn)
    }

    @Test("A scheduler error is a failed install")
    func failedInstall() {
        #expect(SteamLogs.installPhase(appID: 1, contentLog: """
        [t] AppID 1 App update changed : Running Update,Downloading,
        [t] AppID 1 scheduler finished : removed from schedule (result Disk Write Failure, state 0x402)
        """) == .failed("Disk Write Failure"))
    }
}

@Suite("Steam session store")
struct SteamSessionStoreTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("steam-session-\(UUID().uuidString)")
    var store: SteamSessionStore { SteamSessionStore(root: base.appendingPathComponent("store")) }

    /// A prefix holding a signed-in session whose token is `token`, written at `date`.
    func prefix(_ name: String, token: String, user: String = "someone", date: Date = Date()) throws -> URL {
        let prefix = base.appendingPathComponent(name)
        for file in SteamSessionStore.files {
            let url = prefix.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(file.split(separator: "/").last ?? ""): \(token)".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Valve\\\\Steam\\\\ActiveProcess] 1792400000
        "AutoLoginUser"="not this one"

        [Software\\\\Valve\\\\Steam] 1792400000
        #time=1dc4c0000000000
        "AutoLoginUser"="\(user)"
        "Language"="english"

        """.write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        return prefix
    }

    @Test("The registry value is read from its own key only")
    func readsRegistryValue() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try prefix("a", token: "t1", user: #"some \"one\""#)
        #expect(try SteamSessionStore.registryLine(inUserReg: source.appendingPathComponent("user.reg")) == #""AutoLoginUser"="some \"one\"""#)
        let crlf = base.appendingPathComponent("crlf.reg")
        try "[Software\\\\Valve\\\\Steam] 1\r\n\"AutoLoginUser\"=\"x\"\r\n".write(to: crlf, atomically: true, encoding: .utf8)
        #expect(try SteamSessionStore.registryLine(inUserReg: crlf) == #""AutoLoginUser"="x""#)
    }

    @Test("Capture then restore carries the session into another prefix")
    func roundTrip() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let source = try prefix("a", token: "t1", date: date)
        #expect(!store.hasSession)
        #expect(try store.capture(from: source, signedIn: true) == .saved)
        #expect(store.hasSession)
        #expect(try store.capture(from: source, signedIn: true) == .unchanged)

        let target = base.appendingPathComponent("b")
        let fragment = try #require(try store.restore(into: target))
        for file in SteamSessionStore.files {
            let copied = target.appendingPathComponent(file)
            #expect(try Data(contentsOf: copied) == Data(contentsOf: source.appendingPathComponent(file)))
            let modified = try FileManager.default.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date
            #expect(modified == date)
        }
        #expect(fragment == target.appendingPathComponent(SteamSessionStore.fragmentPathInPrefix))
        let reg = try String(contentsOf: fragment, encoding: .utf8)
        #expect(reg.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        #expect(reg.contains("[HKEY_CURRENT_USER\\Software\\Valve\\Steam]\r\n\"AutoLoginUser\"=\"someone\"\r\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.sessionDir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test("A run that didn't sign in never overwrites the session")
    func notSignedIn() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try store.capture(from: try prefix("a", token: "good"), signedIn: true) == .saved)
        let rejected = try prefix("b", token: "cleared by Steam", date: Date().addingTimeInterval(60))
        #expect(try store.capture(from: rejected, signedIn: false) == .notSignedIn)
        let restored = base.appendingPathComponent("c")
        try store.restore(into: restored)
        #expect(try String(contentsOf: restored.appendingPathComponent(SteamSessionStore.tokenFile), encoding: .utf8).hasSuffix("good"))
    }

    @Test("An older session doesn't replace a newer one")
    func newerWins() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        #expect(try store.capture(from: try prefix("new", token: "new", date: now), signedIn: true) == .saved)
        #expect(try store.capture(from: try prefix("old", token: "old", date: now.addingTimeInterval(-60)), signedIn: true) == .storeIsNewer)
        #expect(try store.capture(from: try prefix("newer", token: "newer", date: now.addingTimeInterval(60)), signedIn: true) == .saved)
    }

    @Test("A prefix missing part of the session isn't saved")
    func incomplete() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try prefix("a", token: "t")
        try FileManager.default.removeItem(at: source.appendingPathComponent(SteamSessionStore.files[0]))
        #expect(try store.capture(from: source, signedIn: true) == .incomplete(SteamSessionStore.files[0]))
        #expect(!store.hasSession)
    }

    @Test("Stripping a prefix leaves no sign-in and nothing naming the account")
    func strip() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try prefix("a", token: "t", user: "someone")
        SteamSessionStore.strip(from: source)
        for file in SteamSessionStore.files {
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent(file).path))
        }
        let reg = try String(contentsOf: source.appendingPathComponent("user.reg"), encoding: .utf8)
        #expect(!reg.contains("someone"))
        #expect(reg.contains(#""Language"="english""#))  // the rest of the key stays
        #expect(reg.contains(#""AutoLoginUser"="not this one""#))  // another key's value of the same name
    }

    @Test("Without a session, restore does nothing; signing out removes it")
    func signOut() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try store.restore(into: base.appendingPathComponent("x")) == nil)
        try store.capture(from: try prefix("a", token: "t"), signedIn: true)
        try store.signOut()
        #expect(!store.hasSession)
        try store.signOut()  // twice is fine
    }
}

@Suite("Steam active-wrapp lock")
struct SteamActiveLockTests {
    @Test("A second taker is told who holds it, until it's released")
    func exclusive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .acquired(let first) = try SteamActiveLock.acquire(root: root, bundleID: "au.example.one") else {
            Issue.record("the first acquire should succeed")
            return
        }
        guard case .heldBy(let holder) = try SteamActiveLock.acquire(root: root, bundleID: "au.example.two") else {
            Issue.record("the second acquire should find it held")
            return
        }
        #expect(holder == SteamLockHolder(pid: getpid(), bundleID: "au.example.one"))
        // This process isn't an app with that bundle ID: nothing to name or quit.
        #expect(holder.name == nil)
        #expect(!holder.canQuit)
        first.release()
        first.release()
        guard case .acquired(let again) = try SteamActiveLock.acquire(root: root, bundleID: "au.example.two") else {
            Issue.record("it should be free once released")
            return
        }
        again.release()
    }

    @Test("A build holding it is named as Second Chance, and never offered to be quit")
    func buildHolder() {
        let holder = SteamLockHolder(pid: getpid(), bundleID: SteamLockHolder.buildBundleID)
        #expect(holder.isBuild)
        #expect(holder.name == "Second Chance")
        #expect(!holder.canQuit)
    }

    @Test("The alert offers to quit only a game it can find, and never as the default")
    @MainActor
    func alertChoices() {
        let unknown = SteamLockHolder(pid: nil, bundleID: "au.example.gone").alert(blocked: "the game can't start until it quits.")
        #expect(unknown.0.messageText == "Another game is using Steam")
        #expect(unknown.0.buttons.map(\.title) == ["Try Again", "Cancel"])
        #expect(unknown.1 == [.tryAgain, .cancel])

        let build = SteamLockHolder(pid: getpid(), bundleID: SteamLockHolder.buildBundleID).alert(blocked: "the game can't start until it quits.")
        #expect(build.0.messageText == "Second Chance is adding a game from Steam")
        #expect(build.1 == [.tryAgain, .cancel])
    }

    @Test("Waiting for a process that has already gone returns at once")
    func waitForExitOfGoneProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(SteamLockHolder.waitForExit(of: process.processIdentifier, timeout: 5))
    }

    @Test("Waiting for a process that is still running times out")
    func waitForExitOfRunningProcess() {
        #expect(!SteamLockHolder.waitForExit(of: getpid(), timeout: 0.2))
    }
}
