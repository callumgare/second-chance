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

    @Test("A no macOS recorded is explained, with the switch and the reset that put it right")
    func deniedExplained() {
        let message = AudioTapSetup.deniedMessage(host: "meeka", user: "second-chance-testing-5")
        #expect(message.contains("meeka/second-chance-testing-5") && message.contains("won't ask again"))
        let fix = AudioTapSetup.deniedFix(user: "second-chance-testing-5", mac: "meeka")
        #expect(fix.contains("System Audio Recording Only"))
        #expect(fix.contains("ssh second-chance-testing-5@meeka 'tccutil reset AudioCapture au.gare.callum.second-chance.sc-audio-tap'"))
        #expect(fix.hasSuffix("sc session setup --task audio second-chance-testing-5 --on meeka"))
        #expect(AudioTapSetup.deniedFix(user: "u", mac: nil).contains("ssh u@localhost"))
    }
}
