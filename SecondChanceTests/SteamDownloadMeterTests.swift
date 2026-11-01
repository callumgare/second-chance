//
//  SteamDownloadMeterTests.swift
//  SecondChanceTests
//
//  Measuring Steam's download by Wine's network traffic.

import Foundation
import Testing
@testable import SecondChance

@Suite("Steam download meter")
struct SteamDownloadMeterTests {
    @Test("Wine's processes are summed from a nettop sample, everything else left out")
    func nettop() {
        // The shape of a real sample taken mid-download: one connection's
        // count sits with wineserver in one sample and the program in the next.
        let sample = """
        ,bytes_in,bytes_out,
        kernel_task.0,691357,464392,
        apsd.727,383228,1103705,
        wineserver.28342,1729691808,1420070,
        wine.28383,681910451,580950,
        steamwebhelper.exe.28470,19878417,65901,
        """
        let wine: Int64 = 1_729_691_808 + 681_910_451 + 19_878_417
        #expect(NettopNetworkCounter.wineBytes(inNettop: sample) == wine)
        #expect(NettopNetworkCounter.wineBytes(inNettop: ",bytes_in,bytes_out,\napsd.727,1,2,") == 0)
        #expect(NettopNetworkCounter.wineBytes(inNettop: "nettop: something went wrong") == nil)
    }

    @Test("Counting starts at the first sample, and only growth counts")
    func counting() {
        let start = Date()
        var meter = SteamDownloadMeter(total: 1_000, now: start)
        meter.add(400, at: start)
        #expect(meter.received == 0)
        meter.add(650, at: start.addingTimeInterval(5))
        #expect(meter.received == 250)
        // A process exiting takes its count with it.
        meter.add(600, at: start.addingTimeInterval(10))
        #expect(meter.received == 250)
        meter.add(700, at: start.addingTimeInterval(15))
        #expect(meter.received == 350)
        #expect(meter.fraction == 0.35)
        #expect(meter.quietFor(now: start.addingTimeInterval(20)) == 5)
    }

    @Test("The fraction stops short of the end, which Steam's own traffic would pass")
    func neverFull() {
        let start = Date()
        var meter = SteamDownloadMeter(total: 1_000, now: start)
        meter.add(0, at: start)
        meter.add(1_050, at: start.addingTimeInterval(1))
        #expect(meter.fraction == 0.99)
    }

    @Test("Figures, then the time left once there's a rate to go on")
    func text() {
        let start = Date()
        var meter = SteamDownloadMeter(total: 2_400_000_000, now: start)
        meter.add(0, at: start)
        #expect(meter.text(now: start) == "0 bytes of 2.4 GB")
        meter.add(600_000_000, at: start.addingTimeInterval(5))
        #expect(meter.text(now: start.addingTimeInterval(5)) == "600 MB of 2.4 GB")
        meter.add(1_200_000_000, at: start.addingTimeInterval(20))
        // 60 MB/s over the last 20 s, 1.2 GB to go.
        #expect(meter.text(now: start.addingTimeInterval(20)) == "1.2 GB of 2.4 GB, less than a minute left")
    }

    @Test("Time left in round figures", arguments: [
        (30.0, "1 GB of 2 GB, less than a minute left"),
        (70.0, "1 GB of 2 GB, about a minute left"),
        (200.0, "1 GB of 2 GB, about 3 minutes left"),
        (4_000.0, "1 GB of 2 GB, about an hour left"),
        (9_000.0, "1 GB of 2 GB, about 3 hours left"),
    ])
    func timeLeft(seconds: TimeInterval, expected: String) {
        #expect(SteamDownloadMeter.text(done: "1 GB", of: "2 GB", secondsLeft: seconds) == expected)
    }
}
