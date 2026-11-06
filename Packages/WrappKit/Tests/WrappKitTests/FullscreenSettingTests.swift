//
//  FullscreenSettingTests.swift
//  WrappKitTests
//
//  Allegro's packfiles, and a launch's fullscreen setting read, checked and
//  written (docs/wine-in-process-helpers.md#the-players-choice-kept).

import Foundation
import Testing
@testable import WindowsFormats
@testable import WrappFormat

@Suite("Allegro packfiles")
struct AllegroPackfileTests {
    /// Icy Tower's tower.cfg as it wrote it, saved with Options › GFX ›
    /// Fullscreen: Yes and No.
    static let savedFullscreen = Data(base64Encoded: """
        c2xoISmW6/Tq8QHr8P/+8OL5/2hhcm9sZF90/2hlX2hvbWViY2953P8xD+T3yBX48/9GTEQA2AGFAF+IAwAAOuvwEuvw744NyXFW\
        AQAAbL8AtwIAAC/r8A9e6/BBwhIZVgXX+vD1I+vwC+vwxdkBoa5uAwAAF/rwF+vwB17r8OnF7VueBXeTBL5fAAAtTXmvVgG4xFsP\
        bQIg6gB2D3ABdQKQjg+gD7IPxAuo0w9tBACAdQ/nBAYfGB8qH8QH/vFSquvwU+vwVOvwVevwSwrr8EPr8BA8D+wf/h8QLg==
        """)
    static let savedWindowed = Data(base64Encoded: """
        c2xoIemW6/Tq8QHc/wBoYf9yb2xkX3RoZf9faG9tZWJvedj8/zEP5PfZFfjzRkz/RADYAYUAiAPXAAA66/AS6/CODfvJcVYBAABs\
        ALevAgAAL+vwD+vwQVfCEhlWBdf68CPr8L0L6/DF2QGhbgMAqwAX+vAX6/AH6/Dpl8XtW54Fd5MEXwAALy1Nea9WAbhbD20CMSDq\
        AHYPcAF1Ao4PoA8ksg/EC6jTD20EAHUP5wRQBh8YHyofxAf/vhBS6/BVU+vwVOvwVevwS+vwBUPr8BA8D+wf/h8QLg==
        """)

    @Test("Icy Tower's packed tower.cfg unpacks to its 564 bytes, the fullscreen flag at 16")
    func unpacksIcyTower() throws {
        let fullscreen = try AllegroPackfile.read(try #require(Self.savedFullscreen))
        let windowed = try AllegroPackfile.read(try #require(Self.savedWindowed))
        #expect(fullscreen.packed && windowed.packed)
        #expect(fullscreen.contents.count == 564 && windowed.contents.count == 564)
        #expect(fullscreen.contents[16..<20] == Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(windowed.contents[16..<20] == Data([0, 0, 0, 0]))
        // The default high-score table's first name.
        #expect(String(decoding: windowed.contents[32..<50], as: UTF8.self) == "harold_the_homeboy")
    }

    @Test("What it writes reads back the same, packed or not")
    func roundTrips() throws {
        let contents = try AllegroPackfile.read(try #require(Self.savedWindowed)).contents
        for packed in [true, false] {
            let file = AllegroPackfile.write(contents, packed: packed)
            #expect(file.prefix(4) == (packed ? AllegroPackfile.packedMagic : AllegroPackfile.unpackedMagic))
            let read = try AllegroPackfile.read(file)
            #expect(read.contents == contents)
            #expect(read.packed == packed)
        }
        #expect(try AllegroPackfile.read(AllegroPackfile.write(Data(), packed: true)).contents.isEmpty)
    }

    @Test("A file that isn't one, or is cut short partway through an item, is refused")
    func refusesCorrupt() throws {
        #expect(throws: AllegroPackfile.Error.notAPackfile) { try AllegroPackfile.read(Data("[settings]".utf8)) }
        #expect(throws: AllegroPackfile.Error.notAPackfile) { try AllegroPackfile.read(Data("slh".utf8)) }
        // A flags byte saying a reference follows, and only one of its two bytes.
        #expect(throws: AllegroPackfile.Error.truncated(at: 5)) {
            try AllegroPackfile.read(AllegroPackfile.packedMagic + Data([0x00, 0x12]))
        }
        let saved = try #require(Self.savedFullscreen)
        #expect(throws: AllegroPackfile.Error.self) { try AllegroPackfile.read(saved.prefix(saved.count - 1)) }
    }
}

@Suite("A launch's fullscreen setting")
struct FullscreenSettingTests {
    static let icyTower = "file=C:/IcyTower/tower.cfg,format=allegro-packfile,offset=16,bytes=4,fullscreen=-1,windowed=0,checksum-offset=96,checksum-scale=17"

    @Test("Icy Tower's reads as its file, format, place and values")
    func parses() throws {
        let setting = try FullscreenSetting(parsing: Self.icyTower)
        #expect(setting.file == "C:/IcyTower/tower.cfg")
        #expect(setting.format == .allegroPackfile)
        #expect(setting.offset == 16 && setting.width == 4)
        #expect(setting.fullscreen == Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(setting.windowed == Data([0, 0, 0, 0]))
        #expect(setting.checksum == .init(offset: 96, scale: 17))
        // In full form, and with hex and one byte.
        let other = try FullscreenSetting(parsing: "file=wine:C:/Game/game.dat,format=bytes,offset=3,bytes=1,fullscreen=0x01,windowed=0")
        #expect(other.file == "C:/Game/game.dat" && other.fullscreen == Data([1]) && other.checksum == nil)
        let launch = RecordedLaunch(program: "wine:C:/IcyTower/icytower13.exe", options: [FullscreenSetting.option: Self.icyTower])
        #expect(launch.fullscreenSetting == setting)
        #expect(RecordedLaunch(program: "wine:C:/Game.exe").fullscreenSetting == nil)
    }

    @Test("A bad value is refused, saying what's wrong", arguments: [
        ("file=C:/a.cfg,format=allegro-packfile,offset=16,bytes=4,fullscreen=-1", "windowed="),
        ("file=D:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=-1,windowed=0", "C: drive"),
        ("file=C:/a.cfg,format=ini,offset=16,bytes=4,fullscreen=-1,windowed=0", "allegro-packfile or bytes"),
        ("file=C:/a.cfg,format=bytes,offset=-2,bytes=4,fullscreen=-1,windowed=0", "offset=-2"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=3,fullscreen=-1,windowed=0", "1, 2, 4 or 8"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=1,fullscreen=256,windowed=0", "fullscreen=256"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=1,fullscreen=-129,windowed=0", "fullscreen=-129"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=yes,windowed=0", "fullscreen=yes"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=0,windowed=0", "the same value"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=1,windowed=0,size=2", "no size"),
        ("file=C:/a.cfg,file=C:/b.cfg,format=bytes,offset=16,bytes=4,fullscreen=1,windowed=0", "twice"),
        ("C:/a.cfg", "isn't <name>=<value>"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=1,windowed=0,checksum-offset=96", "go together"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=1,windowed=0,checksum-offset=18,checksum-scale=17", "apart from the value"),
        ("file=C:/a.cfg,format=bytes,offset=16,bytes=4,fullscreen=1,windowed=0,checksum-offset=96,checksum-scale=0", "checksum-scale=0"),
    ])
    func refuses(text: String, saying: String) {
        #expect {
            try FullscreenSetting(parsing: text)
        } throws: { error in
            "\(error)".contains(saying)
        }
    }

    @Test("-1 and 255 fit a byte, and are the same")
    func values() {
        #expect(FullscreenSetting.littleEndian("-1", width: 1) == Data([0xFF]))
        #expect(FullscreenSetting.littleEndian("255", width: 1) == Data([0xFF]))
        #expect(FullscreenSetting.littleEndian("0x1234", width: 2) == Data([0x34, 0x12]))
        #expect(FullscreenSetting.littleEndian("-1", width: 8) == Data(repeating: 0xFF, count: 8))
        #expect(FullscreenSetting.littleEndian("65536", width: 2) == nil)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FullscreenSettingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The player's choice is written through the link into the store, packed as the game writes it")
    func writesThroughLink() throws {
        let setting = try FullscreenSetting(parsing: Self.icyTower)
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("store.cfg"), link = folder.appendingPathComponent("tower.cfg")
        try #require(AllegroPackfileTests.savedWindowed).write(to: store)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store)

        #expect(setting.apply(fullscreen: true, at: link) == .written)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == store.path)
        let read = try AllegroPackfile.read(Data(contentsOf: store))
        #expect(read.packed)
        // Just what the game itself saves with Fullscreen: Yes, its sum at
        // 96 included, which it checks as it loads.
        #expect(read.contents == (try AllegroPackfile.read(try #require(AllegroPackfileTests.savedFullscreen)).contents))

        let before = try Data(contentsOf: store)
        #expect(setting.apply(fullscreen: true, at: link) == .alreadySet)
        #expect(try Data(contentsOf: store) == before)
        #expect(setting.apply(fullscreen: false, at: link) == .written)
        #expect(try AllegroPackfile.read(Data(contentsOf: store)).contents
            == (try AllegroPackfile.read(try #require(AllegroPackfileTests.savedWindowed)).contents))
    }

    @Test("A file that's missing, short, of another format or with another value there is left alone")
    func leavesAlone() throws {
        let setting = try FullscreenSetting(parsing: Self.icyTower)
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tower.cfg")

        guard case .leftAlone = setting.apply(fullscreen: true, at: file) else { Issue.record("a missing file was written"); return }
        for contents in [Data("[ini]\nfullscreen=1\n".utf8),
                         AllegroPackfile.write(Data(count: 18), packed: true),
                         AllegroPackfile.write(Data(repeating: 7, count: 564), packed: true)] {
            try contents.write(to: file)
            guard case .leftAlone = setting.apply(fullscreen: true, at: file) else {
                Issue.record("\(contents.count) bytes were written over")
                continue
            }
            #expect(try Data(contentsOf: file) == contents)
        }
    }

    @Test("Plain bytes are counted in the file as it is")
    func plainBytes() throws {
        let setting = try FullscreenSetting(parsing: "file=C:/g/g.dat,format=bytes,offset=2,bytes=2,fullscreen=1,windowed=0")
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("g.dat")
        try Data([9, 9, 1, 0, 9]).write(to: file)
        #expect(setting.apply(fullscreen: false, at: file) == .written)
        #expect(try Data(contentsOf: file) == Data([9, 9, 0, 0, 9]))
    }
}
