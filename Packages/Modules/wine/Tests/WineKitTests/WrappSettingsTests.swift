//
//  WrappSettingsTests.swift
//  SecondChanceTests
//
//  What a wrapp records about its game, where things are inside it, and its
//  prefix's drive letters.

import Foundation
import Testing
import GameCatalog
@testable import ProcessKit
@testable import WineKit
@testable import WindowsFormats
@testable import WrappFormat
@testable import WrappLogging

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
            source: .steam, installerDir: "/nancy-drew-installer/disk-1", steamAppID: "42210", steamLaunchMode: "steam"
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

    @Test("Drives are links, kept as given, and blocked letters are files, device links too")
    func drives() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        try drives.mount("../drive_c", as: "c")
        try drives.mount(URL(fileURLWithPath: "/tmp/saves"), as: "A")
        drives.block("de")
        #expect(try drives.target(of: "c") == "../drive_c")
        #expect(try drives.target(of: "a") == "/tmp/saves")
        let names = try FileManager.default.contentsOfDirectory(atPath: drives.folder.path).sorted()
        #expect(names == ["a:", "a::", "c:", "c::", "d:", "d::", "e:", "e::"])
        for letter in "acde" {
            #expect(try kind(drives.deviceLink(letter)) == .typeRegular)
        }

        try drives.mount("/tmp/other", as: "a")
        #expect(try drives.target(of: "a") == "/tmp/other")
    }

    /// What is at `url` itself, a link not followed.
    func kind(_ url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    @Test("Blocking a mounted letter removes the link, not what it shows")
    func blockingAMountedLetter() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let shown = FileManager.default.temporaryDirectory.appendingPathComponent("drives-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shown, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shown) }
        let drives = Wine(wrapp: wrapp).drives
        try drives.mount(shown, as: "z")
        drives.block("z")
        #expect(throws: (any Error).self) { try drives.target(of: "z") }
        #expect(FileManager.default.fileExists(atPath: drives.link("z").path))
        #expect(FileManager.default.fileExists(atPath: shown.path))
    }

    @Test("A lent folder is Y: until it is taken back")
    func lending() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        drives.block("y")
        try drives.lend(URL(fileURLWithPath: "/tmp/Downloads"))
        #expect(try drives.target(of: "Y") == "/tmp/Downloads")
        drives.takeBack()
        #expect(throws: (any Error).self) { try drives.target(of: "y") }
        #expect(FileManager.default.fileExists(atPath: drives.link("y").path))
    }

    @Test("Mounting or blocking a letter blocks the Mac disk Wine noted there", arguments: [true, false])
    func staleDeviceLink(mounting: Bool) throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        try drives.mount("../drive_c", as: "c")
        drives.block("y")
        // What Wine's mount manager leaves for a disc the Mac had mounted.
        try FileManager.default.removeItem(at: drives.deviceLink("y"))
        try FileManager.default.createSymbolicLink(
            atPath: drives.deviceLink("y").path, withDestinationPath: "/dev/rdisk10")
        if mounting {
            try drives.lend(URL(fileURLWithPath: "/tmp/Downloads"))
            #expect(try drives.target(of: "y") == "/tmp/Downloads")
        } else {
            drives.block("y")
        }
        #expect(try kind(drives.deviceLink("y")) == .typeRegular)
        let names = try FileManager.default.contentsOfDirectory(atPath: drives.folder.path)
        #expect(names.sorted() == ["c:", "c::", "y:", "y::"])
    }

    @Test("Showing only C: blocks every other letter and every device link, and leaves nothing else")
    func showOnly() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        // As wineboot leaves a prefix: Z: the whole Mac, the Mac's discs given
        // letters with their device links, and the drive_c link.
        try FileManager.default.createDirectory(at: drives.folder, withIntermediateDirectories: true)
        for (name, target) in [("c:", "../drive_c"), ("z:", "/"), ("d:", "/Volumes/DISC"), ("d::", "/dev/rdisk10")] {
            try FileManager.default.createSymbolicLink(
                atPath: drives.folder.appendingPathComponent(name).path, withDestinationPath: target)
        }
        FileManager.default.createFile(atPath: drives.folder.appendingPathComponent("leftover").path, contents: nil)

        try drives.showOnly("../drive_c", as: "c")

        let names = try FileManager.default.contentsOfDirectory(atPath: drives.folder.path).sorted()
        #expect(names == "abcdefghijklmnopqrstuvwxyz".flatMap { ["\($0):", "\($0)::"] }.sorted())
        #expect(try drives.target(of: "c") == "../drive_c")
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            if letter != "c" { #expect(try kind(drives.link(letter)) == .typeRegular) }
            #expect(try kind(drives.deviceLink(letter)) == .typeRegular)
        }
    }

    @Test("Blocking device links leaves the drives be")
    func blockingDeviceLinks() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        try drives.mount("../drive_c", as: "c")
        try FileManager.default.removeItem(at: drives.deviceLink("c"))
        try FileManager.default.createSymbolicLink(
            atPath: drives.deviceLink("y").path, withDestinationPath: "/dev/rdisk10")

        drives.blockDevices()

        #expect(try drives.target(of: "c") == "../drive_c")
        #expect(!FileManager.default.fileExists(atPath: drives.link("y").path))
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(try kind(drives.deviceLink(letter)) == .typeRegular)
        }
    }

    @Test("A drive replaced over a folder at its name still ends up a link")
    func replacingAFolder() throws {
        defer { try? FileManager.default.removeItem(at: wrapp) }
        let drives = Wine(wrapp: wrapp).drives
        try FileManager.default.createDirectory(at: drives.link("d"), withIntermediateDirectories: true)
        try drives.mount("/tmp/disc", as: "d")
        #expect(try drives.target(of: "d") == "/tmp/disc")
        #expect(try FileManager.default.contentsOfDirectory(atPath: drives.folder.path).sorted() == ["d:", "d::"])
    }
}
