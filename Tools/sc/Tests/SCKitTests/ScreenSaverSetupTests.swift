import Testing
@testable import SCKit

@Suite("Screen saver set-up")
struct ScreenSaverSetupTests {
    @Test("An idle time of 0 is off; unset (macOS's 20 minutes) or any other is on",
          arguments: [("0\n", true), ("0", true), ("", false), ("1200\n", false), ("300", false)])
    func readsIdleTime(output: String, off: Bool) {
        #expect(ScreenSaverSetup.isOff(output) == off)
    }

    @Test("The setup task is offered and runs first")
    func taskIsListed() {
        #expect(SessionSetupCommand.Task.allCases.first == .screensaver)
        #expect(SessionSetupCommand.Task(rawValue: "screensaver") == .screensaver)
    }

    @Test("Users named that aren't the Mac's test users are found before any waiting")
    func namedUsersOutsideThePool() {
        let pool = ["second-chance-testing-1", "second-chance-testing-2"]
        #expect(SessionSetupCommand.notInPool(["second-chance-testing-2"], pool: pool).isEmpty)
        #expect(SessionSetupCommand.notInPool(["second-chance-testing-4", "second-chance-testing-1", "second-chance-testing-5"], pool: pool)
                == ["second-chance-testing-4", "second-chance-testing-5"])
        #expect(SessionSetupCommand.notInPool(["a"], pool: []) == ["a"])
    }
}
