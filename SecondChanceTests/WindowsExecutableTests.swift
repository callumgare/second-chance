//
//  WindowsExecutableTests.swift
//  SecondChanceTests
//
//  Reading the strings in a Windows program's version info, which is how a
//  game's installer is recognised. The images are built here, byte by byte,
//  so these run without any real installer; GameGraphicsAPITests covers the
//  imports.

import Foundation
import Testing
@testable import SecondChance

@Suite("Windows executable")
struct WindowsExecutableTests {
    @Test("A program's version strings are read")
    func readsVersionStrings() throws {
        let image = TestPE.image(versionInfo: TestPE.versionInfo(tables: [
            ("040904b0", [("ProductName", "Nancy Drew: Danger by Design"), ("Comments", "InstallShield"),
                          ("CompanyName", "Her Interactive")]),
        ]))
        let strings = try #require(WindowsExecutable(data: image)).versionStrings
        #expect(strings == [
            "ProductName": "Nancy Drew: Danger by Design",
            "Comments": "InstallShield",
            "CompanyName": "Her Interactive",
        ])
    }

    @Test("VarFileInfo before StringFileInfo doesn't hide the strings")
    func readsStringsAfterVarFileInfo() throws {
        let image = TestPE.image(versionInfo: TestPE.versionInfo(
            tables: [("040904b0", [("ProductName", "Inno Setup")])], varFileInfoFirst: true))
        #expect(try #require(WindowsExecutable(data: image)).versionStrings == ["ProductName": "Inno Setup"])
    }

    @Test("US English wins over the first table, and the first is taken without it")
    func picksUSEnglish() throws {
        let both = TestPE.image(versionInfo: TestPE.versionInfo(tables: [
            ("040704b0", [("ProductName", "Nancy Drew: Geheimnis")]),
            ("040904b0", [("ProductName", "Nancy Drew: Secrets")]),
        ]))
        #expect(try #require(WindowsExecutable(data: both)).versionStrings["ProductName"] == "Nancy Drew: Secrets")

        let german = TestPE.image(versionInfo: TestPE.versionInfo(tables: [
            ("040704b0", [("ProductName", "Nancy Drew: Geheimnis")]),
        ]))
        #expect(try #require(WindowsExecutable(data: german)).versionStrings["ProductName"] == "Nancy Drew: Geheimnis")
    }

    @Test("A missing or empty string is absent, not another string's value")
    func missingStringIsAbsent() throws {
        let image = TestPE.image(versionInfo: TestPE.versionInfo(tables: [
            ("040904b0", [("ProductName", ""), ("Comments", "Created with Inno Setup")]),
        ]))
        let strings = try #require(WindowsExecutable(data: image)).versionStrings
        #expect(strings == ["Comments": "Created with Inno Setup"])
    }

    @Test("A string whose length counts bytes rather than characters is read whole")
    func readsByteCountedString() throws {
        let image = TestPE.image(versionInfo: TestPE.versionInfo(
            tables: [("040904b0", [("ProductName", "Stay Tuned for Danger")])], textLengthInBytes: true))
        #expect(try #require(WindowsExecutable(data: image)).versionStrings["ProductName"] == "Stay Tuned for Danger")
    }

    @Test("A program with no version info has no strings")
    func noVersionInfo() throws {
        let image = GameGraphicsAPITests.peImage(importing: ["kernel32.dll"])
        #expect(try #require(WindowsExecutable(data: image)).versionStrings.isEmpty)
    }

    @Test("A truncated or damaged program gives fewer strings, never a crash")
    func survivesDamage() {
        let image = TestPE.image(versionInfo: TestPE.versionInfo(tables: [
            ("040904b0", [("ProductName", "Nancy Drew"), ("Comments", "InstallShield")]),
        ]))
        for length in stride(from: 0, through: image.count, by: 7) {
            _ = WindowsExecutable(data: image.prefix(length))?.versionStrings
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var damaged = image
            for _ in 0..<4 {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = WindowsExecutable(data: damaged)?.versionStrings
            _ = WindowsExecutable(data: damaged)?.importedDLLs
        }
    }

    @Test("A slice of a larger buffer reads the same as a copy")
    func readsFromSlice() throws {
        let image = TestPE.image(versionInfo: TestPE.versionInfo(tables: [("040904b0", [("ProductName", "Wine")])]))
        let padded = Data(repeating: 0xAA, count: 13) + image
        let slice = padded[13...]
        #expect(try #require(WindowsExecutable(data: slice)).versionStrings == ["ProductName": "Wine"])
    }

    static let winesExplorer = Bundle.main.resourceURL?.appendingPathComponent(
        "WrappTemplate.app/Contents/SharedSupport/wine/lib/wine/i386-windows/explorer.exe")

    @Test("Wine's own explorer.exe reads as Wine",
          .enabled(if: winesExplorer.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                   "No Wine bundled in the test host"))
    func readsWinesExplorer() throws {
        let explorer = try #require(Self.winesExplorer)
        let strings = try #require(WindowsExecutable(contentsOf: explorer)).versionStrings
        #expect(strings["ProductName"] == "Wine")
        #expect(strings["CompanyName"] == "Microsoft Corporation")
    }
}

/// Minimal PE32 images holding a version resource, for reading back.
enum TestPE {
    typealias StringTable = (language: String, strings: [(key: String, value: String)])

    /// One section, holding the resource directory: RT_VERSION → name 1 →
    /// language 0x409 → `versionInfo`.
    static func image(versionInfo: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        let pe = 0x40, optional = pe + 24, optionalSize = 224
        let directories = optional + 96
        let section = optional + optionalSize
        let sectionRVA = 0x1000, sectionFileOffset = 0x400

        bytes.put16(0x5A4D, at: 0)  // MZ
        bytes.put32(pe, at: 0x3C)
        bytes.put32(0x0000_4550, at: pe)  // PE\0\0
        bytes.put16(1, at: pe + 6)  // one section
        bytes.put16(optionalSize, at: pe + 20)
        bytes.put16(0x10B, at: optional)
        bytes.put32(16, at: directories - 4)  // NumberOfRvaAndSizes
        bytes.put32(sectionRVA, at: directories + 2 * 8)  // the resource directory

        var resources = [UInt8](repeating: 0, count: 0x58)
        // Root: one numbered entry, RT_VERSION, a subdirectory at 0x18.
        resources.put16(1, at: 14)
        resources.put32(16, at: 16)
        resources.put32(0x8000_0018, at: 20)
        // Name 1, a subdirectory at 0x30.
        resources.put16(1, at: 0x18 + 14)
        resources.put32(1, at: 0x18 + 16)
        resources.put32(0x8000_0030, at: 0x18 + 20)
        // Language 0x409, its data entry at 0x48.
        resources.put16(1, at: 0x30 + 14)
        resources.put32(0x409, at: 0x30 + 16)
        resources.put32(0x48, at: 0x30 + 20)
        // The data entry: the resource's RVA and size.
        resources.put32(sectionRVA + 0x58, at: 0x48)
        resources.put32(versionInfo.count, at: 0x48 + 4)
        resources += versionInfo

        bytes.put32(resources.count, at: section + 8)  // VirtualSize
        bytes.put32(sectionRVA, at: section + 12)
        bytes.put32(resources.count, at: section + 16)  // SizeOfRawData
        bytes.put32(sectionFileOffset, at: section + 20)
        return Data(bytes + resources)
    }

    /// A VS_VERSIONINFO tree holding `tables`. `textLengthInBytes` writes a
    /// string's value length as bytes, as some programs wrongly do.
    static func versionInfo(tables: [StringTable], varFileInfoFirst: Bool = false,
                            textLengthInBytes: Bool = false) -> [UInt8] {
        let stringFileInfo = node("StringFileInfo", children: tables.map { table in
            node(table.language, children: table.strings.map { key, value in
                let text = Array(value.utf16) + [0]
                return node(key, value: text.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] },
                            valueLength: textLengthInBytes ? text.count * 2 : text.count, isText: true)
            })
        })
        let varFileInfo = node("VarFileInfo", children: [node("Translation", value: [0x09, 0x04, 0xB0, 0x04])])
        var fixedInfo = [UInt8](repeating: 0, count: 52)
        fixedInfo.put32(0xFEEF_04BD, at: 0)
        return node("VS_VERSION_INFO", value: fixedInfo,
                    children: varFileInfoFirst ? [varFileInfo, stringFileInfo] : [stringFileInfo, varFileInfo])
    }

    /// One node: its lengths and type, its key, padding, its value, padding,
    /// then its children, each padded to 32 bits.
    private static func node(_ key: String, value: [UInt8] = [], valueLength: Int? = nil,
                             isText: Bool = false, children: [[UInt8]] = []) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 6)
        for unit in Array(key.utf16) + [0] { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        bytes.padTo32Bits()
        bytes += value
        for child in children {
            bytes.padTo32Bits()
            bytes += child
        }
        bytes.put16(bytes.count, at: 0)
        bytes.put16(valueLength ?? value.count, at: 2)
        bytes.put16(isText ? 1 : 0, at: 4)
        return bytes
    }
}

/// Writing the little-endian integers test images are made of.
extension Array where Element == UInt8 {
    mutating func put16(_ value: Int, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8 & 0xFF)
    }

    mutating func put32(_ value: Int, at offset: Int) {
        put16(value & 0xFFFF, at: offset)
        put16(value >> 16 & 0xFFFF, at: offset + 2)
    }

    mutating func padTo32Bits() {
        while count % 4 != 0 { append(0) }
    }
}
