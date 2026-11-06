import Foundation
import Testing
@testable import SCKit

@Suite("Test sessions")
struct TestSessionTests {
    private func hex(_ text: String) -> Data {
        var digits = Array(text.dropFirst(2))
        if digits.count % 2 == 1 { digits.insert("0", at: 0) }
        return Data(stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) })
    }

    @Test("Powers modulo an odd number match Python's pow() for a 1024-bit key")
    func modularPower() throws {
        // random.seed(7); p = getrandbits(1024) | 1<<1023 | 1; pow(b, e, p)
        let prime = hex(
            "0xa170b33839263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a3" +
            "5a099950d836f675cc81e74ef5e8e25d940ed904759531985d5d9dc9f81818e811892f902bd23f0824128b2f330c5c7fd0a6a3a4506513270e269e0d" +
            "37f2a74de452e6b439")
        let base = hex(
            "0x185f557203301850c5a38fd547923a736994e3bf911a61dbe22e44158bae97ba94d0eda82f8f6d05584ef8aa38922766581e27a1c08a6a63ec24ed" +
            "e6a46b4cb2424a23d5962217beaddbc496cb8e81973e0becd7b03898d190f9ebdacc0cb1e29c658cda1495e60af593bd04cf0fd630f1f29d0da9953f" +
            "48f1a09f76b5")
        let exponent = hex(
            "0x57ee05cde00902c77ebff206867347214cdd2055930d6eaf14f4733f3e7d1bfbc7a2ea20b2f14c942e05319acb5c74273f98e2774cbd87ad5c90a9" +
            "587403e430ec66a78795e761d17731af10506bf2efc6f877186d76b07e881ed162ae2eb1547f15052434b9b5df9e7769b10f4205b4907a70c31012f0" +
            "37b64ce4228c38fb29")
        let expected = hex(
            "0x3dbe7be173ee5e69396218b876984555a7b328950bb8d1f6c6608b6e1af475d49eb659e0a34f88cb99b316a8d6948315d87f55dfc65b2ab0911aa8" +
            "826f1af3c1d604187a4deff118b2061f9f46c46675a7527cd5db4ffe5f7421ca6f7f3cbb19c2098525d14a778793fabd68db7d99b434164e3eb56427" +
            "5e9eccc72b2183724e")
        let arithmetic = try #require(ModularArithmetic(modulus: prime))
        #expect(arithmetic.power(base, exponent) == expected)
    }

    @Test("A small power comes back padded to the modulus's length")
    func smallPower() throws {
        // pow(2, 12345, 2**127 - 1) == 0x4000000
        let arithmetic = try #require(ModularArithmetic(modulus: hex("0x7fffffffffffffffffffffffffffffff")))
        let result = arithmetic.power(Data([2]), Data([0x30, 0x39]))
        #expect(result.count == 16)
        #expect(result == Data(repeating: 0, count: 12) + Data([0x04, 0, 0, 0]))
        #expect(ModularArithmetic(modulus: Data([0x10])) == nil)
    }

    @Test("The login's credentials are two 64-byte fields, each ended by a NUL")
    func credentials() {
        let data = ScreenSharingConnection.credentials(user: "sctest", password: "pass word")
        #expect(data.count == 128)
        #expect(data.prefix(7) == Data("sctest\0".utf8))
        #expect(data[64..<74] == Data("pass word\0".utf8))
    }

    @Test("AES-128-ECB encrypts the FIPS-197 test block")
    func aes() throws {
        let key = hex("0x000102030405060708090a0b0c0d0e0f")
        let block = hex("0x00112233445566778899aabbccddeeff")
        #expect(try ScreenSharingConnection.encrypt(block, key: key) == hex("0x69c4e0d86a7b0430d8cdb78070b4c55a"))
    }

    @Test("The pool lists one user a line, without comments or blanks")
    func pool() {
        #expect(SessionPool.users(fromPool: "sctest\n\n  sctest2  # the second\n# off: sctest3\n") == ["sctest", "sctest2"])
        #expect(SessionPool.screenName(of: "sctest2", host: "mac", pool: ["sctest2"]) == "sctest2@mac")
        #expect(SessionPool.screenName(of: "person", host: "mac", pool: ["sctest2"]) == "mac")
    }

    @Test("Logins come from ioreg's console users, locked or not")
    func logins() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>IOConsoleUsers</key><array>
        <dict><key>kCGSSessionOnConsoleKey</key><true/><key>kCGSSessionUserNameKey</key><string>person</string>
        <key>kCGSSessionUserIDKey</key><integer>501</integer></dict>
        <dict><key>kCGSSessionOnConsoleKey</key><false/><key>kCGSSessionUserNameKey</key><string>sctest</string>
        <key>kCGSSessionUserIDKey</key><integer>502</integer><key>CGSSessionScreenIsLocked</key><true/></dict>
        </array></dict></plist>
        """
        let logins = SessionPool.logins(fromIORegPlist: Data(plist.utf8))
        #expect(logins == [
            SessionPool.Login(user: "person", uid: 501, onConsole: true, locked: false),
            SessionPool.Login(user: "sctest", uid: 502, onConsole: false, locked: true),
        ])
    }

    @Test("Each user's lease is a file of its own beside the others")
    func leaseFiles() {
        let environment = [ScreenLease.fileVariable: "/tmp/leases/\(NSUserName()).json"]
        #expect(ScreenLease.file(environment: environment).path == "/tmp/leases/\(NSUserName()).json")
        #expect(ScreenLease.file(for: "sctest2", environment: environment).path == "/tmp/leases/sctest2.json")
        #expect(ScreenLease.file(for: "sctest2", environment: [:]).path == "/Users/Shared/second-chance/leases/sctest2.json")
    }

    @Test("A test session's hint reaches it as <user>@<mac>")
    func hintTarget() {
        let lease = ScreenLease(holder: .init(agentSocket: nil, sessionID: nil, agentPID: nil, host: "laptop", user: "someone",
                                              checkout: "/c", branch: nil),
                                purpose: nil, command: "sc wrapp run skifree", runCheckout: "/Users/sctest/tmp/second-chance",
                                pid: 1, pidStarted: 0, started: Date())
        #expect(lease.hints(onHost: "sctest@mac", askingSession: nil).contains("Watch it: sc --on sctest@mac:/Users/sctest/tmp/second-chance attach"))
    }

    @Test("New test users take the lowest numbers no user has")
    func names() {
        #expect(SessionPool.nextNames(1, taken: []) == ["second-chance-testing-1"])
        #expect(SessionPool.nextNames(3, taken: ["sctest", "second-chance-testing-2", "callumgare"])
            == ["second-chance-testing-1", "second-chance-testing-3", "second-chance-testing-4"])
    }

    @Test("sc session add takes names, or a count of numbered ones")
    func addArguments() throws {
        let numbered = try #require(try SC.parseAsRoot(["session", "add", "--count", "3"]) as? SessionAddCommand)
        #expect(numbered.users.isEmpty && numbered.count == 3)
        let named = try #require(try SC.parseAsRoot(["session", "add", "sctest", "second-chance-testing-7"]) as? SessionAddCommand)
        #expect(named.users == ["sctest", "second-chance-testing-7"])
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["session", "add", "Bad Name"]) }
    }

    @Test("sc session add makes the next free name, or the count given, or checks the names given")
    func addNames() {
        let taken: Set = ["second-chance-testing-1", "second-chance-testing-2"]
        #expect(SessionAddCommand.names(given: [], count: nil, taken: taken) == ["second-chance-testing-3"])
        #expect(SessionAddCommand.names(given: [], count: nil, taken: []) == ["second-chance-testing-1"])
        #expect(SessionAddCommand.names(given: [], count: 2, taken: taken) == ["second-chance-testing-3", "second-chance-testing-4"])
        #expect(SessionAddCommand.names(given: ["sctest"], count: nil, taken: taken) == ["sctest"])
    }

    @Test("sc session add gives a new user a UID no account has and no process runs as")
    func freeUID() {
        #expect(SessionPool.freeUID(accounts: [], running: []) == 501)
        #expect(SessionPool.freeUID(accounts: [501, 502, 503], running: [0, 501]) == 504)
        // A deleted account's processes still running as 504.
        #expect(SessionPool.freeUID(accounts: [501, 502, 503], running: [504]) == 505)
        #expect(SessionPool.freeUID(accounts: [501, 503], running: []) == 502)
    }

    @Test("sc session add counts the pool's users and accounts named as test users outside it as existing")
    func existingTestUsers() {
        let taken: Set = ["callum", "sctest", "second-chance-testing-1", "second-chance-testing-10", "second-chance-testing-2"]
        #expect(SessionAddCommand.existingTestUsers(pool: ["sctest", "second-chance-testing-1"], taken: taken)
                == ["sctest", "second-chance-testing-1", "second-chance-testing-2", "second-chance-testing-10"])
        #expect(SessionAddCommand.existingTestUsers(pool: [], taken: ["callum"]).isEmpty)
    }

    @Test("An SCError shown with localizedDescription says its message")
    func errorMessage() {
        #expect(SCError("No password for x").localizedDescription == "No password for x")
    }
}

@Suite("Peekaboo in test sessions")
struct PeekabooSetupTests {
    @Test("Missing grants are the required ones Peekaboo says it lacks")
    func missingGrants() {
        let json = """
        {"data":{"permissions":[{"name":"Screen Recording","isRequired":true,"isGranted":false},
        {"name":"Accessibility","isRequired":true,"isGranted":true},
        {"name":"Event Synthesizing","isRequired":false,"isGranted":false}]},"success":true}
        """
        #expect(PeekabooSetup.missing(fromPermissionsJSON: Data(json.utf8)) == ["Screen Recording"])
        #expect(PeekabooSetup.missing(fromPermissionsJSON: Data("not json".utf8)) == ["Screen Recording", "Accessibility"])
    }

    @Test("session setup keeps --on for itself; other commands run there")
    func runsHere() {
        #expect(Remote.runsHere(["session", "setup", "sctest"]))
        #expect(Remote.runsHere(["session", "screenshot"]))
        #expect(Remote.runsHere(["session", "view", "sctest"]))
        #expect(Remote.followedBySetup(["session", "add", "--count", "2"]))
        let setup = try? SC.parseAsRoot(["session", "setup", "--task", "signing", "--task", "peekaboo"]) as? SessionSetupCommand
        #expect(setup?.only == [.signing, .peekaboo])
        #expect((try? SC.parseAsRoot(["session", "setup", "sctest", "sctest2"]) as? SessionSetupCommand)?.users == ["sctest", "sctest2"])
        #expect(throws: (any Error).self) { _ = try SC.parseAsRoot(["session", "setup", "--just-added"]) }
        #expect(!Remote.followedBySetup(["session", "add", "--no-setup"]))
        #expect(!Remote.followedBySetup(["session", "list"]))
        #expect(throws: (any Error).self) { _ = try SC.parseAsRoot(["session", "remove"]) }
        #expect((try? SC.parseAsRoot(["session", "remove", "sctest2", "--delete-account"])) is SessionRemoveCommand)
        let port = try? Network.freePort()
        #expect(port.map { $0 > 1024 } == true)
        #expect(!Remote.runsHere(["session", "list"]))
        #expect(!Remote.runsHere(["puppet", "start"]))
    }

    @Test("Installers are sent only to commands whose sources may read them")
    func readsInstallers() {
        #expect(!Remote.readsInstallers(["test", "integration", "laser-tank", "--source", "download"]))
        #expect(!Remote.readsInstallers(["test", "integration", "--source=download,big-fish-trial"]))
        #expect(Remote.readsInstallers(["test", "integration", "--source", "download,disk"]))
        #expect(Remote.readsInstallers(["test", "integration", "royal-tower"]))
        #expect(!Remote.readsInstallers(["wrapp", "build", "skifree", "--from", "download"]))
        #expect(Remote.readsInstallers(["test", "integration", "--source", "all"]))
        #expect(!Remote.readsInstallers(["installers", "list"]))
    }

    @Test("A program run in the GUI session hands its output back through a pipe, not a file")
    func guiSessionScript() {
        let script = TestSessionAccess.inGUISession(["/usr/bin/open", "x?a&b"])
        #expect(script.contains("mkfifo -m 600"))
        #expect(script.contains("<string>x?a&amp;b</string>"))
        #expect(script.contains("launchctl bootstrap gui/$(id -u)"))
    }

    @Test("A new test user's Setup Assistant is marked done for this macOS")
    func setupAssistant() {
        let script = SessionAddCommand.setupAssistantDoneScript(build: "25G332", version: "26.4")
        #expect(script.contains("/usr/bin/defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true"))
        #expect(script.contains("LastSeenBuddyBuildVersion -string '25G332'"))
        #expect(script.contains("LastSeenCloudProductVersion -string '26.4'"))
        #expect(!script.contains("; "))
    }

    @Test("Test users let in the keys this user lets in and this user's own, each once")
    func authorizedKeys() throws {
        let ssh = FileManager.default.temporaryDirectory.appendingPathComponent("sc-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ssh) }
        try "ssh-ed25519 AAA other@mac\n# a comment\nssh-ed25519 BBB mine@here\n".write(to: ssh.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        try "ssh-ed25519 BBB mine@here\n".write(to: ssh.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        try "ssh-rsa CCC mine@here\n".write(to: ssh.appendingPathComponent("id_rsa.pub"), atomically: true, encoding: .utf8)
        try "private".write(to: ssh.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
        #expect(SessionAddCommand.authorizedKeys(ssh: ssh) == ["ssh-ed25519 AAA other@mac", "ssh-ed25519 BBB mine@here", "ssh-rsa CCC mine@here"])
    }
}
