import Foundation
import Testing
@testable import SecondChance

@Suite("Running Steam, stopped on quit")
struct RunningSteamTests {
    @Test("Only one of the build and a quit gets to stop Steam")
    func claimOnce() {
        let run = SteamRun()
        #expect(run.claimStop() == false)  // not started
        run.started()
        #expect(run.claimStop() == true)
        #expect(run.claimStop() == false)
    }

    @Test("Quitting runs every registered stop once, and unregistered ones not at all")
    func stopAll() async {
        let registry = RunningSteam()
        let calls = CallLog()
        _ = registry.register { calls.record("build") }
        let gone = registry.register { calls.record("finished build") }
        registry.unregister(gone)
        #expect(!registry.isEmpty)
        await registry.stopAll()
        await registry.stopAll()
        #expect(calls.all == ["build"])
        #expect(registry.isEmpty)
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var all: [String] { lock.withLock { _calls } }
    func record(_ name: String) { lock.withLock { _calls.append(name) } }
}
