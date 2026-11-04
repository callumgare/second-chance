import Testing
import Foundation
@testable import ProcessKit
@testable import WineKit
@testable import WindowsFormats
@testable import WrappFormat
@testable import WrappLogging

@Suite("Subprocess watch and Wine run naming")
struct SubprocessWatchTests {

    @Test("Wine runs are named after the program they run", arguments: [
        (["start", "/wait", "/unix", "/private/var/x/disk-1/setup.exe", "/verysilent"], "wine setup.exe"),
        (["reg", "add", "HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives"], "wine reg"),
        (["C:\\nancy-drew-installer\\disk-combined\\ndsck1.exe"], "wine ndsck1.exe"),
        ([], "wine"),
    ])
    func names(arguments: [String], expected: String) {
        #expect(WineCommand.wine(arguments).displayName == expected)
    }

    @Test("Other executables keep their own name")
    func otherExecutables() {
        #expect(WineCommand.wineserver(["-w"]).displayName == "wineserver")
        #expect(WineCommand.script(URL(fileURLWithPath: "/x/winetricks"), ["cnc_ddraw"]).displayName == "winetricks")
    }

    @Test("Durations read naturally")
    func durations() {
        #expect(SubprocessWatch.duration(17.14) == "17.1s")
        #expect(SubprocessWatch.duration(245) == "4m 05s")
    }

    @Test("Signals are named")
    func signals() {
        #expect(SubprocessWatch.signalName(SIGKILL) == "SIGKILL (9)")
        #expect(SubprocessWatch.signalName(64) == "signal (64)")
    }

    @Test("The re-run command holds only the variables Second Chance sets")
    func reproductionCommand() {
        let wine = Wine(wrapp: URL(fileURLWithPath: "/tmp/Test Wrapp.app"))
        let command = WineCommand.wine(["reg", "add", "it's"]).commandLine(in: wine)
        #expect(command.hasPrefix("env \\\n"))
        #expect(command.contains("  WINEPREFIX='/tmp/Test Wrapp.app/Contents/SharedSupport/prefix' \\"))
        #expect(!command.contains("SSH_AUTH_SOCK"))
        #expect(!command.contains("HOME="))
        #expect(command.hasSuffix("'/tmp/Test Wrapp.app/Contents/SharedSupport/wine/bin/wine' 'reg' 'add' 'it'\\''s'"))
    }
}
