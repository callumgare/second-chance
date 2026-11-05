import Darwin
import Foundation
import Testing
@testable import SCKit

@Suite("Screen lease")
struct ScreenLeaseTests {
    private func holder(socket: String? = "/tmp/cc-socks/123.sock", session: String? = "abc") -> ScreenLease.Holder {
        ScreenLease.Holder(agentSocket: socket, sessionID: session, agentPID: 123, host: "kiya", user: "someone",
                           checkout: "/Users/someone/code/second-chance", branch: "main")
    }

    private func lease(pid: pid_t = getpid(), started: Date = Date()) -> ScreenLease {
        ScreenLease(holder: holder(), purpose: "Bioscopia play test", command: "sc test integration ghost-dogs",
                    runCheckout: "/Users/someone/tmp/second-chance", pid: pid,
                    pidStarted: ProcessFacts.startTime(of: pid) ?? 0, started: started)
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-lease-tests-\(UUID().uuidString)/screen-lease.json")
    }

    @Test("An agent session's identity comes from its environment, and never its token")
    func holderFromAgent() throws {
        let environment = [
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/66079.sock",
            "CLAUDE_CODE_SESSION_ID": "3e6d2128",
            "CLAUDE_PID": "66079",
            "CLAUDE_CODE_MESSAGING_TOKEN": "secret-token",
        ]
        let found = ScreenLease.currentHolder(repoRoot: URL(fileURLWithPath: "/r"), branch: "main", environment: environment)
        #expect(found.agentSocket == "/tmp/cc-socks/66079.sock")
        #expect(found.sessionID == "3e6d2128")
        #expect(found.agentPID == 66079)
        #expect(found.checkout == "/r")
        let json = String(decoding: try JSONEncoder().encode(found), as: UTF8.self)
        #expect(!json.contains("secret-token"))
    }

    @Test("A person's run has no agent fields")
    func holderFromPerson() {
        let found = ScreenLease.currentHolder(repoRoot: URL(fileURLWithPath: "/r"), branch: nil, environment: [:])
        #expect(found.agentSocket == nil)
        #expect(found.sessionID == nil)
        #expect(found.user == NSUserName())
    }

    @Test("--on hands the holder over as one shell-safe word, which wins over the remote's own")
    func holderForwarded() {
        let original = holder()
        let encoded = ScreenLease.encodeHolder(original)
        #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        let found = ScreenLease.currentHolder(repoRoot: URL(fileURLWithPath: "/elsewhere"), branch: "other",
                                              environment: [ScreenLease.holderVariable: encoded, "CLAUDE_PID": "9"])
        #expect(found == original)
        let command = Remote.remoteCommand(path: "~/sc", arguments: ["lease"], leaseHolder: original)
        #expect(command == "cd ~/'sc' && env \(ScreenLease.holderVariable)=\(encoded) ./sc 'lease'")
    }

    @Test("Only one lease can be created at a time")
    func exclusive() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(try ScreenLease.create(lease(), at: file))
        #expect(try !ScreenLease.create(lease(), at: file))
        #expect(ScreenLease.read(file) == lease().withStarted(ScreenLease.read(file)?.started))
    }

    @Test("A lease is live only while the process that took it runs")
    func liveness() {
        #expect(lease().isAlive)
        // No such process.
        var gone = lease(pid: 99_999)
        gone.pidStarted = 1
        #expect(!gone.isAlive)
        // Our pid, but a different start: the pid was reused.
        var reused = lease()
        reused.pidStarted -= 3600
        #expect(!reused.isAlive)
    }

    @Test("The parent of a re-run is recognised as its ancestor")
    func ancestor() {
        #expect(ProcessFacts.isAncestor(getppid(), of: getpid()))
        #expect(!ProcessFacts.isAncestor(getpid(), of: getppid()))
    }

    @Test("A blocked run says who has the screen and how to reach them")
    func message() {
        let held = lease(started: Date().addingTimeInterval(-125 * 60))
        let text = held.heldMessage(onHost: "meeka")
        #expect(text.contains("meeka's screen is in use"))
        #expect(text.contains("/tmp/cc-socks/123.sock"))
        #expect(text.contains("2 h 5 min"))
        #expect(text.contains("Bioscopia play test"))
        #expect(text.contains("branch main"))
        let hints = held.hints(onHost: "meeka", askingSession: "other")
        #expect(hints.contains { $0.contains("uds:/tmp/cc-socks/123.sock") })
        #expect(hints.contains { $0.contains("sc --on meeka:/Users/someone/tmp/second-chance attach") })
        #expect(hints.contains { $0.contains("--ignore-screen-lease") })
        #expect(hints.contains { $0.contains("--break-screen-lease") })
        #expect(held.hints(onHost: "meeka", askingSession: "abc").first?.contains("same agent session") == true)
    }

    @Test("Durations read naturally", arguments: [
        (20.0, "under a minute"), (60.0, "1 minute"), (14 * 60.0, "14 minutes"), (120 * 60.0, "2 h"), (61 * 60.0, "1 h 1 min"),
    ] as [(Double, String)])
    func durations(seconds: Double, text: String) {
        #expect(ScreenLease.duration(seconds) == text)
    }

    @Test("Host names are shortened to how the Mac is reached")
    func hostNames() {
        #expect(ScreenLease.shortHostName("meeka.silas.internal") == "meeka")
        #expect(ScreenLease.shortHostName("kiya.local") == "kiya")
        #expect(ScreenLease.shortHostName("kiya") == "kiya")
    }

    @Test("The command is shown as it would be typed")
    func commandLine() {
        #expect(ScreenLease.commandLine(["wrapp", "run", "x", "--purpose", "a check"]) == "sc wrapp run x --purpose 'a check'")
    }

    @Test("A lease taken by hand lives until it expires, with no process")
    func takenByHand() {
        var taken = lease()
        taken.pid = 0
        taken.pidStarted = 0
        taken.expires = Date().addingTimeInterval(600)
        #expect(taken.isTakenByHand)
        #expect(taken.isAlive)
        taken.expires = Date().addingTimeInterval(-1)
        #expect(!taken.isAlive)
        taken.expires = nil
        #expect(!taken.isAlive)
    }

    @Test("A lease taken by hand says until when, and offers no attach")
    func takenMessage() {
        var taken = lease(started: Date().addingTimeInterval(-300))
        taken.pid = 0
        taken.expires = Date().addingTimeInterval(1500)
        #expect(taken.heldMessage(onHost: "meeka").contains("took it by hand 5 minutes ago, until"))
        let hints = taken.hints(onHost: "meeka", askingSession: "other")
        #expect(!hints.contains { $0.contains("attach") })
        #expect(hints.contains { $0.contains("Clear their lease") })
    }

    @Test("The same asker is the same agent session, or the same person on the same Mac")
    func sameHolder() {
        let agent = holder(session: "abc")
        #expect(agent.isSame(as: holder(socket: "/tmp/other.sock", session: "abc")))
        #expect(!agent.isSame(as: holder(session: "xyz")))
        let person = holder(socket: nil, session: nil)
        #expect(person.isSame(as: holder(socket: nil, session: nil)))
        #expect(!person.isSame(as: agent))
    }

    @Test("Durations for lease take", arguments: [
        ("30m", 1800.0), ("2h", 7200.0), ("90s", 90.0), ("45", 2700.0), ("9h", nil), ("0", nil), ("soon", nil),
    ] as [(String, Double?)])
    func takeDurations(text: String, seconds: Double?) {
        #expect(ScreenLease.parseDuration(text) == seconds)
    }

    @Test("lease, like attach, doesn't sync")
    func leaseDoesNotSync() {
        #expect(!Remote.syncs(["lease"]))
        #expect(!Remote.syncs(["lease", "take", "--for", "30m"]))
    }

    @Test("The flags pick the policy, break winning")
    func policy() throws {
        #expect(try GlobalOptions.parse([]).leasePolicy == .respect)
        #expect(try GlobalOptions.parse(["--ignore-screen-lease"]).leasePolicy == .ignore)
        #expect(try GlobalOptions.parse(["--ignore-screen-lease", "--break-screen-lease"]).leasePolicy == .breakIt)
        #expect(try GlobalOptions.parse(["--purpose", "x"]).purpose == "x")
    }
}

private extension ScreenLease {
    /// Dates lose sub-second precision through ISO 8601.
    func withStarted(_ date: Date?) -> ScreenLease {
        var copy = self
        if let date { copy.started = date }
        return copy
    }
}
