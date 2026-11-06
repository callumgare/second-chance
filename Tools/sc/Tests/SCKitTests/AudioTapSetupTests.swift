import Testing
@testable import SCKit

@Suite("SC Audio Tap's set-up")
struct AudioTapSetupTests {
    @Test("The tap's answer is its last permission line, unknown when it gave none")
    func readsThePermission() {
        #expect(AudioTapSetup.permission(fromOutput: "permission authorized\n") == "authorized")
        #expect(AudioTapSetup.permission(fromOutput: "starting\npermission unknown\npermission denied") == "denied")
        #expect(AudioTapSetup.permission(fromOutput: "") == "unknown")
    }

    @Test("Its executable in a test user's home, where puppet audio installs it")
    func executablePath() {
        #expect(AudioTapSetup.remoteExecutable(home: "/Users/t")
                == "/Users/t/Library/Application Support/SecondChance/sc-audio-tap/SC Audio Tap.app/Contents/MacOS/sc-audio-tap")
    }

    @Test("--task audio is a set-up task")
    func isATask() {
        #expect(SessionSetupCommand.Task(rawValue: "audio") == .audio)
    }
}
