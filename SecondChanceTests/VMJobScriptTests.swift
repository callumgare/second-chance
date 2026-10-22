import Testing
import Foundation
@testable import SecondChance

/// The scripts `VMPuppetRunner` runs in a test VM. The runs themselves need
/// a VM (`sc test integration --vm`); these check what's sent to one.
@Suite("VM job scripts")
struct VMJobScriptTests {

    /// Whether bash parses `script` (`bash -n`), without running it.
    private func parses(_ script: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test("The job script is valid bash and opens the wrapp once before WrappPuppeteer")
    func jobScript() throws {
        let script = VMPuppetRunner.jobScript(job: "/tmp/sc-vm-test-abcd1234", bundleID: "au.gare.callum.SecondChance.nancy-drew.ghost-dogs",
                                              gameSlug: "ghost-dogs", timeout: 90)
        #expect(try parses(script))
        #expect(script.contains("Logs/SecondChance/ghost-dogs"))
        let warmUp = try #require(script.range(of: "open -g -j -n \"$wrapp\""))
        let puppeteer = try #require(script.range(of: "WrappPuppeteer.app/Contents/MacOS/WrappPuppeteer"))
        #expect(warmUp.lowerBound < puppeteer.lowerBound)
        #expect(script.contains("nancy-drew.ghost-dogs/dont-show-save-warning"))
    }

    @Test("Cleanup never matches its own command line, and removes the job", arguments: [
        ("/tmp/sc-vm-test-abcd1234", "pkill -9 -f '/tmp/sc-vm-test-abcd123[4]'", "rm -rf /tmp/sc-vm-test-abcd1234*"),
        ("/tmp/sc-vm-tes[t]-", "pkill -9 -f '/tmp/sc-vm-tes[t]-'", "rm -rf /tmp/sc-vm-test-*"),
    ])
    func cleanup(jobPattern: String, pkill: String, remove: String) throws {
        let script = VMPuppetRunner.cleanupScript(agentPattern: "vm-test.", jobPattern: jobPattern)
        #expect(try parses(script))
        #expect(script.contains(pkill))
        #expect(script.contains(remove))
    }

    @Test("Paths are quoted for the shell, leaving ~/ to expand")
    func quoting() {
        #expect(VMPuppetRunner.quoted("~/Library/Application Support/SecondChance") == "~/'Library/Application Support/SecondChance'")
        #expect(VMPuppetRunner.quoted("/tmp/it's") == #"'/tmp/it'\''s'"#)
    }
}
