//
//  WrappSettingsTests.swift
//  SecondChanceTests
//
//  What a wrapp records about its game, where things are inside it, and its
//  prefix's drive letters.

import Foundation
import Testing
import GameCatalog
@testable import SecondChanceKit

@Suite("Wrapp settings, layout and drives")
struct WrappSettingsTests {
    let wrapp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WrappSettingsTests-\(UUID().uuidString).app")

    @Test("Settings read back as they were written")
    func roundTrip() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let layout = WrappLayout(app: wrapp)
        let settings = WrappSettings(
            gameExePath: "/Program Files (x86)/Nancy Drew/Game.exe", engine: .wineSteam, gameSlug: "royal-tower",
            source: .steam, installerDir: "/nancy-drew-installer/disk-1", steamAppID: "42210", steamLaunchMode: .steam
        )
        try settings.write(to: layout)
        #expect(try WrappSettings(of: layout) == settings)
    }

    @Test("A wrapp's plist keeps the keys wrapps have always had")
    func keys() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let layout = WrappLayout(app: wrapp)
        try WrappSettings(gameExePath: "/Game.exe", engine: .wine, gameSlug: "royal-tower", source: .disk,
                          installerDir: "/nancy-drew-installer/disk-1").write(to: layout)
        let plist = try #require(NSDictionary(contentsOf: layout.settingsFile) as? [String: String])
        #expect(plist == [
            "GameExePath": "/Game.exe", "GameEngine": "wine", "GameSlug": "royal-tower",
            "GameSource": "disk", "GameInstallerDir": "/nancy-drew-installer/disk-1",
        ])
    }

    @Test("A wrapp built before the slug and source were recorded still reads")
    func olderWrapp() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let layout = WrappLayout(app: wrapp)
        try FileManager.default.createDirectory(at: layout.resources, withIntermediateDirectories: true)
        let old: NSDictionary = ["GameExePath": "/Game.exe", "GameEngine": "wine-steam-silent",
                                 "GameInstallerDir": "/nancy-drew-installer/disk-1", "SteamGameId": "42210"]
        try old.write(to: layout.settingsFile)
        let settings = try WrappSettings(of: layout)
        #expect(settings.engine == .wineSteamSilent)
        #expect(settings.steamAppID == "42210")
        #expect(settings.gameSlug == nil)
        #expect(settings.source == nil)
    }

    @Test("A path on the C: drive is found whether or not it starts with a slash")
    func driveCPaths() {
        let layout = WrappLayout(app: URL(fileURLWithPath: "/Apps/Game.app"))
        #expect(layout.onDriveC("/Program Files/Game.exe").path
                == "/Apps/Game.app/Contents/SharedSupport/prefix/drive_c/Program Files/Game.exe")
        #expect(layout.onDriveC("Program Files/Game.exe") == layout.onDriveC("/Program Files/Game.exe"))
    }

    @Test("Drives are links, kept as given, and blocked letters are files")
    func drives() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        try drives.mount("../drive_c", as: "c")
        try drives.mount(URL(fileURLWithPath: "/tmp/saves"), as: "A")
        drives.block("de")
        #expect(try drives.target(of: "c") == "../drive_c")
        #expect(try drives.target(of: "a") == "/tmp/saves")
        let names = try FileManager.default.contentsOfDirectory(atPath: drives.folder.path).sorted()
        #expect(names == ["a:", "c:", "d:", "e:"])

        try drives.mount("/tmp/other", as: "a")
        #expect(try drives.target(of: "a") == "/tmp/other")

        drives.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: drives.folder.path).isEmpty)
    }
}
