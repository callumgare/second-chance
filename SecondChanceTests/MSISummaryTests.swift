//
//  MSISummaryTests.swift
//  SecondChanceTests
//
//  Reading an MSI's subject, which names the game on discs that have no
//  other sign of it. The compound files are built here, so these run without
//  any real installer.

import Foundation
import Testing
@testable import SecondChance

@Suite("MSI summary")
struct MSISummaryTests {
    @Test("An MSI's subject is read")
    func readsSubject() throws {
        let msi = TestMSI.file(summary: TestMSI.summaryInformation(subject: "Nancy Drew: The Haunting of Castle Malloy"))
        #expect(try #require(MSISummary(data: msi)).subject == "Nancy Drew: The Haunting of Castle Malloy")
    }

    @Test("A subject is read in the summary's code page")
    func readsCodePage() throws {
        // ’ is 0x92 in Windows-1252.
        let subject = Array("Nancy Drew: Shadow at the Water".utf8) + [0x92] + Array("s Edge".utf8)
        let msi = TestMSI.file(summary: TestMSI.summaryInformation(subjectBytes: subject, codePage: 1252))
        #expect(try #require(MSISummary(data: msi)).subject == "Nancy Drew: Shadow at the Water’s Edge")
    }

    @Test("A summary stream bigger than the mini stream cutoff is read from regular sectors")
    func readsRegularStream() throws {
        let msi = TestMSI.file(summary: TestMSI.summaryInformation(subject: "Nancy Drew: Sea of Darkness"),
                               miniStreamCutoff: 64)
        #expect(try #require(MSISummary(data: msi)).subject == "Nancy Drew: Sea of Darkness")
    }

    @Test("Summary information without a subject has none")
    func noSubject() throws {
        let msi = TestMSI.file(summary: TestMSI.summaryInformation(subject: nil))
        #expect(try #require(MSISummary(data: msi)).subject == nil)
    }

    @Test("Something that isn't a compound file, or has no summary, isn't read")
    func rejectsOthers() {
        #expect(MSISummary(data: GameGraphicsAPITests.peImage(importing: ["kernel32.dll"])) == nil)
        #expect(MSISummary(data: Data()) == nil)
        #expect(MSISummary(data: TestMSI.file(summary: TestMSI.summaryInformation(subject: "X"),
                                              streamName: "\u{5}DocumentSummaryInformation")) == nil)
        #expect(MSISummary(contentsOf: URL(fileURLWithPath: "/nonexistent/Setup.msi")) == nil)
    }

    @Test("A truncated or damaged MSI gives no subject, never a crash or a hang")
    func survivesDamage() {
        let msi = TestMSI.file(summary: TestMSI.summaryInformation(subject: "Nancy Drew"))
        for length in stride(from: 0, through: msi.count, by: 11) {
            _ = MSISummary(data: msi.prefix(length))?.subject
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var damaged = msi
            for _ in 0..<4 {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = MSISummary(data: damaged)?.subject
        }
    }

    @Test("A FAT chain that loops ends rather than spinning")
    func survivesLoopingChain() {
        var msi = [UInt8](TestMSI.file(summary: TestMSI.summaryInformation(subject: "Nancy Drew")))
        // Point the directory's sector (1) at itself.
        msi.put32(1, at: 512 + 1 * 4)
        _ = MSISummary(data: Data(msi))
    }
}

/// Minimal version 3 compound files: 512-byte sectors, with the header, then
/// the FAT (sector 0), the directory (1), the mini FAT (2), and the mini
/// stream (3 on) holding one stream.
enum TestMSI {
    static func file(summary: [UInt8], streamName: String = "\u{5}SummaryInformation",
                     miniStreamCutoff: Int = 4096) -> Data {
        let sector = 512, endOfChain = 0xFFFF_FFFE, free = 0xFFFF_FFFF
        let inMiniStream = summary.count < miniStreamCutoff
        let streamSectors = (summary.count + (inMiniStream ? 63 : 511)) / (inMiniStream ? 64 : 512)
        let dataSectors = inMiniStream ? (streamSectors * 64 + 511) / 512 : streamSectors

        var header = [UInt8](repeating: 0, count: sector)
        header.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.put16(0x3E, at: 0x18)
        header.put16(3, at: 0x1A)
        header.put16(0xFFFE, at: 0x1C)
        header.put16(9, at: 0x1E)
        header.put16(6, at: 0x20)
        header.put32(1, at: 0x2C)  // one FAT sector
        header.put32(1, at: 0x30)  // the directory
        header.put32(miniStreamCutoff, at: 0x38)
        header.put32(2, at: 0x3C)  // the mini FAT
        header.put32(1, at: 0x40)
        header.put32(endOfChain, at: 0x44)  // no DIFAT sectors
        for index in 0..<109 { header.put32(index == 0 ? 0 : free, at: 0x4C + index * 4) }

        var fat = [UInt8](repeating: 0xFF, count: sector)
        fat.put32(0xFFFF_FFFD, at: 0)  // FAT
        fat.put32(endOfChain, at: 4)  // directory
        fat.put32(endOfChain, at: 8)  // mini FAT
        for index in 0..<dataSectors {
            fat.put32(index == dataSectors - 1 ? endOfChain : 3 + index + 1, at: (3 + index) * 4)
        }

        var directory = [UInt8](repeating: 0, count: sector)
        func entry(_ index: Int, name: String, type: Int, start: Int, size: Int) {
            let offset = index * 128
            for (position, unit) in name.utf16.enumerated() { directory.put16(Int(unit), at: offset + position * 2) }
            directory.put16((name.utf16.count + 1) * 2, at: offset + 0x40)
            directory[offset + 0x42] = UInt8(type)
            for link in [0x44, 0x48, 0x4C] { directory.put32(free, at: offset + link) }
            directory.put32(start, at: offset + 0x74)
            directory.put32(size, at: offset + 0x78)
        }
        entry(0, name: "Root Entry", type: 5, start: inMiniStream ? 3 : endOfChain,
              size: inMiniStream ? streamSectors * 64 : 0)
        entry(1, name: streamName, type: 2, start: inMiniStream ? 0 : 3, size: summary.count)

        var miniFAT = [UInt8](repeating: 0xFF, count: sector)
        if inMiniStream {
            for index in 0..<streamSectors {
                miniFAT.put32(index == streamSectors - 1 ? endOfChain : index + 1, at: index * 4)
            }
        }

        var data = summary
        data += [UInt8](repeating: 0, count: dataSectors * sector - summary.count)
        return Data(header + fat + directory + miniFAT + data)
    }

    static func summaryInformation(subject: String?) -> [UInt8] {
        summaryInformation(subjectBytes: subject.map { Array($0.utf8) }, codePage: 65001)
    }

    /// A property set stream: the header naming FMTID_SummaryInformation,
    /// then one set holding the code page and, if given, the subject.
    static func summaryInformation(subjectBytes: [UInt8]?, codePage: Int) -> [UInt8] {
        var properties: [(id: Int, value: [UInt8])] = []
        var codePageValue = [UInt8](repeating: 0, count: 8)
        codePageValue.put32(2, at: 0)  // VT_I2
        codePageValue.put16(codePage, at: 4)
        properties.append((1, codePageValue))
        if let subjectBytes {
            var value = [UInt8](repeating: 0, count: 8)
            value.put32(0x1E, at: 0)  // VT_LPSTR
            value.put32(subjectBytes.count + 1, at: 4)
            value += subjectBytes + [0]
            while value.count % 4 != 0 { value.append(0) }
            properties.append((3, value))
        }

        var set = [UInt8](repeating: 0, count: 8 + properties.count * 8)
        for (index, property) in properties.enumerated() {
            set.put32(property.id, at: 8 + index * 8)
            set.put32(set.count, at: 12 + index * 8)
            set += property.value
        }
        set.put32(set.count, at: 0)
        set.put32(properties.count, at: 4)

        var header = [UInt8](repeating: 0, count: 48)
        header.put16(0xFFFE, at: 0)
        header.put32(1, at: 24)
        header.replaceSubrange(28..<44, with: [
            0xE0, 0x85, 0x9F, 0xF2, 0xF9, 0x4F, 0x68, 0x10, 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9,
        ])
        header.put32(48, at: 44)
        return header + set
    }
}
