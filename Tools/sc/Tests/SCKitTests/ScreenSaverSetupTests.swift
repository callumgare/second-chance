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
}
