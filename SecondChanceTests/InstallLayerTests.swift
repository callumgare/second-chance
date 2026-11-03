//
//  InstallLayerTests.swift
//  SecondChanceTests
//
//  A restored install publishes what the install did.

import Foundation
import Testing
import GameCatalog
@testable import SecondChance
@testable import SecondChanceKit

@Suite("Install layer")
struct InstallLayerTests {
    let game = GameInfoProvider.shared.gameInfo(for: "old-clock")

    @Test func whatAnInstallPublishesIsKeptAndGivenBackForTheBuildRestoringIt() throws {
        let disk1 = URL(fileURLWithPath: "/Volumes/OLDCLOCK")
        let events: [WrappBuildEvent] = [
            .disksResolved(disk1: URL(fileURLWithPath: "/Volumes/OTHER"), disk2: nil),
            .engineRouted(composition: game.composition, gameInfo: game),
            .installerResolved(exePath: "C:/nancy-drew-installer/disk-1/setup.exe", type: .installShield),
            .gameExeDetected(path: "/Program Files/Nancy Drew/Game.exe", gameInfo: game),
            .patchApplied(id: "old-clock-1"),
            .progress(.installingGame(substep: nil)),
        ]
        let recorded = events.compactMap(InstallLayer.Recorded.init)
        // Progress is the build's own, not the install's result.
        #expect(recorded.count == 5)
        let data = try JSONEncoder().encode(InstallLayer.Record(
            installed: .init(gameExePath: "/Program Files/Nancy Drew/Game.exe", installerDir: "nancy-drew-installer/disk-1", configuredINI: true),
            events: recorded
        ))
        let record = try JSONDecoder().decode(InstallLayer.Record.self, from: data)
        let replayed = record.events.map { "\($0.event(disk1: disk1, gameInfo: game))" }
        #expect(replayed == [
            "\(WrappBuildEvent.disksResolved(disk1: disk1, disk2: nil))",
            "\(WrappBuildEvent.engineRouted(composition: game.composition, gameInfo: game))",
            "\(WrappBuildEvent.installerResolved(exePath: "C:/nancy-drew-installer/disk-1/setup.exe", type: .installShield))",
            "\(WrappBuildEvent.gameExeDetected(path: "/Program Files/Nancy Drew/Game.exe", gameInfo: game))",
            "\(WrappBuildEvent.patchApplied(id: "old-clock-1"))",
        ])
        #expect(record.installed.configuredINI)
    }

    @Test func underTestOnlyThePrefixIsCachedUnlessSaidOtherwise() {
        #expect(LayerCachePolicy.current(environment: [:]) == (TestHost.isRunning ? .prefix : .all))
        #expect(LayerCachePolicy.current(environment: ["SECOND_CHANCE_LAYER_CACHE": "all"]) == .all)
        #expect(LayerCachePolicy.current(environment: ["SECOND_CHANCE_LAYER_CACHE": "off"]) == .off)
    }
}
