import Foundation
import Testing
@testable import ProcessKit
@testable import WindowsFormats
@testable import WineKit
@testable import WrappFormat
@testable import WrappLogging

@Suite("Shell quoting")
struct ShellQuoteTests {
    @Test("Plain words stay as they are", arguments: ["wine", "/usr/bin/codesign", "--sign", "WINEPREFIX=/tmp/x", "a,b:c@d%e+f"])
    func plain(_ word: String) {
        #expect(shellQuote(word) == word)
    }

    @Test("Anything else is one quoted word that the shell reads back exactly", arguments: [
        "", "Nancy Drew - Stay Tuned for Danger.app", "Water's Edge", "#comment", "a\tb", "line\nbreak", "$HOME", "`date`", "*.exe",
    ])
    func quoted(_ word: String) throws {
        let quoted = shellQuote(word)
        #expect(quoted.hasPrefix("'"))
        // What /bin/sh makes of it is the word itself.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == word)
    }
}
