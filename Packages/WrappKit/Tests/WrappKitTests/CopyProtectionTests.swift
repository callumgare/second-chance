//
//  CopyProtectionTests.swift
//  SecondChanceTests
//
//  Telling a game wrapped in disc copy protection by the sections the
//  wrapper adds to its .exe.

import Foundation
import Testing
@testable import ProcessKit
@testable import WindowsFormats
@testable import WrappFormat
@testable import WrappLogging

@Suite("Copy protection")
struct CopyProtectionTests {
    @Test("A section's name is read, without its padding")
    func readsSectionNames() throws {
        let image = GameGraphicsAPITests.peImage(importing: ["kernel32.dll"], sectionName: ".idata")
        #expect(try #require(WindowsExecutable(data: image)).sectionNames == [".idata"])
        let full = GameGraphicsAPITests.peImage(importing: ["kernel32.dll"], sectionName: ".securom")
        #expect(try #require(WindowsExecutable(data: full)).sectionNames == [".securom"])
    }

    @Test("Each wrapper is told by its own sections", arguments: [
        (".securom", CopyProtection.secuROM), (".cms_t", .secuROM), (".CMS_D", .secuROM),
        ("stxt774", .safeDisc), ("stxt371", .safeDisc), (".sforce3", .starForce),
    ])
    func recognisesWrapper(section: String, protection: CopyProtection) {
        #expect(CopyProtection(sectionNames: [".text", ".rdata", section]) == protection)
        let image = GameGraphicsAPITests.peImage(importing: ["kernel32.dll"], sectionName: section)
        #expect(WindowsExecutable(data: image).flatMap { CopyProtection(sectionNames: $0.sectionNames) } == protection)
    }

    @Test("An ordinary or packed program has none")
    func ordinaryProgram() {
        #expect(CopyProtection(sectionNames: [".text", ".rdata", ".data", ".rsrc", ".reloc"]) == nil)
        #expect(CopyProtection(sectionNames: ["UPX0", "UPX1", ".rsrc"]) == nil)
        #expect(CopyProtection(sectionNames: []) == nil)
    }
}
