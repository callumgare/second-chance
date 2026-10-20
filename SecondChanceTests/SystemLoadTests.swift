//
//  SystemLoadTests.swift
//  SecondChanceTests
//
//  Reading how much CPU other programs are using.

import Foundation
import Testing
@testable import SecondChance

@Suite("System load")
struct SystemLoadTests {
    private let ps = """
      1   0.1 /sbin/launchd
    100  97.5 /usr/bin/yes
    101  96.0 /usr/bin/yes
    200  45.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
    300  80.0 /private/var/folders/xx/T/NancyDrew-1.app/Contents/SharedSupport/wine/bin/wineserver
    301  60.0 /var/folders/xx/T//winetemp-1-2-3/explorer.exe
    302  30.0 /var/folders/xx/T//winetemp-1-2-3/winedevice.exe
    400  99.0 /Applications/Second Chance.app/Contents/MacOS/Second Chance
    """

    @Test("Counts other programs' CPU in cores, leaving out Wine and the caller")
    func countsOthers() {
        let reading = SystemLoad.reading(fromPS: ps, excludingPid: 400, fastCores: 8)
        #expect(abs(reading.otherCores - 2.386) < 0.001)
        #expect(reading.topPrograms.map(\.name) == ["yes"])
        #expect(abs((reading.topPrograms.first?.cores ?? 0) - 1.935) < 0.001)
    }

    @Test("Heavy once other programs use all but one performance core", arguments: [
        (6.7, 8, false), (7.0, 8, true), (9.2, 8, true), (2.9, 4, false), (3.0, 4, true), (0.9, 1, false), (1.0, 1, true),
    ])
    func threshold(otherCores: Double, fastCores: Int, heavy: Bool) {
        let reading = SystemLoadReading(otherCores: otherCores, fastCores: fastCores, topPrograms: [])
        #expect(reading.isHeavy == heavy)
    }

    @Test("Names the busiest programs in its summary")
    func summary() {
        let reading = SystemLoadReading(
            otherCores: 7.42, fastCores: 8,
            topPrograms: [.init(name: "yes", cores: 6), .init(name: "Google Chrome", cores: 1)]
        )
        #expect(reading.summary == "other programs are keeping 7.4 cores busy, and this Mac has 8 performance cores (most: yes, Google Chrome)")
    }

    @Test("Wine's processes are recognised", arguments: [
        ("/var/folders/xx/T//winetemp-1/Game.exe", true),
        // Wine 10 reports the Windows path, with a trailing space
        (#"C:\Program Files (x86)\Her Interactive\Nancy Drew Alibi in Ashes\Alibi.exe "#, true),
        ("/private/var/folders/xx/T/NancyDrew-1.app/Contents/SharedSupport/wine/lib/wine/../../bin/wineserver", true),
        ("/usr/bin/yes", false),
        ("/Applications/Firefox.app/Contents/MacOS/firefox", false),
    ])
    func wineProcesses(command: String, isWine: Bool) {
        #expect(SystemLoad.isWine(command: command) == isWine)
    }

    @Test("Sums up the recent readings for a failure summary")
    func history() throws {
        let now = Date()
        let light = SystemLoadReading(otherCores: 1.2, fastCores: 8, topPrograms: [])
        let heavy = SystemLoadReading(otherCores: 7.9, fastCores: 8, topPrograms: [.init(name: "yes", cores: 7)])
        let text = try #require(SystemLoadHistory.summary(
            of: [(now.addingTimeInterval(-150), light), (now.addingTimeInterval(-60), heavy), (now, light)], now: now))
        #expect(text.hasPrefix("1.2–7.9 cores busy over the last 3 min (busiest at "))
        #expect(text.contains(heavy.summary))
        #expect(text.hasSuffix("; heavily loaded at times"))
        #expect(SystemLoadHistory.summary(of: [], now: now) == nil)
    }

    @Test("A live reading parses")
    func liveReading() throws {
        let reading = try #require(SystemLoad.read())
        #expect(reading.fastCores >= 1)
        #expect(reading.otherCores >= 0)
    }
}
