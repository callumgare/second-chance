@testable import BasiliskExecutor
import Foundation
import Testing

struct BasiliskExecutorTests {
    @Test("A disc image is told from another by its size and first megabyte")
    func fingerprints() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basilisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("one.iso"), two = folder.appendingPathComponent("two.iso")
        try Data(repeating: 1, count: 4096).write(to: one)
        try Data(repeating: 2, count: 4096).write(to: two)
        #expect(try BasiliskExecutor.fingerprint(one) != BasiliskExecutor.fingerprint(two))
        #expect(try BasiliskExecutor.fingerprint(one).hasPrefix("4096-"))
    }

    @Test("A build's prefs boot the tree's disk with its ROM and CDs, at the screen asked for, silent")
    func prefs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basilisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["boot.hfv", "mac.rom", "cdrom-2.iso", "cdrom-1.iso", "notes.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let lines = try BasiliskExecutor.prefs(folder: folder, screen: "800x600x16").split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("cdrom ") } == ["cdrom \(folder.path)/cdrom-1.iso", "cdrom \(folder.path)/cdrom-2.iso"])
        #expect(lines.contains("disk \(folder.path)/boot.hfv"))
        #expect(lines.contains("screen win/800/600"))
        #expect(lines.contains("displaycolordepth 16"))
        #expect(lines.contains("nosound true"))
        #expect(try BasiliskExecutor.prefs(folder: folder, screen: nil).contains("screen win/640/480\n"))
    }

    @Test("The helper's report lines say how the automation went")
    func outcome() {
        let finished = Outcome()
        finished.observe("second-chance-helper[BasiliskMac] notice: automation line 3: key cmd+down")
        #expect(finished.result == nil)
        finished.observe("second-chance-helper[BasiliskMac] notice: automation finished")
        #expect(finished.result == .finished)
        let failed = Outcome()
        failed.observe("second-chance-helper[BasiliskMac] error: automation failed at line 7 (wait-for 60 Agree): not there")
        #expect(failed.result == .failed("automation failed at line 7 (wait-for 60 Agree): not there"))
        failed.observe("second-chance-helper[PuppetControl] notice: automation finished")
        #expect(failed.result == .failed("automation failed at line 7 (wait-for 60 Agree): not there"))
    }
}
