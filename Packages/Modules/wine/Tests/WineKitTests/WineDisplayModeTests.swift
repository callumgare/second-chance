//
//  WineDisplayModeTests.swift
//  WineKitTests
//
//  The program a launch's --wine.display-mode runs.

import Foundation
import Testing
@testable import WineKit

@Suite("Wine display mode")
struct WineDisplayModeTests {
    @Test("The program the wrapp writes out is a 32-bit Windows console program")
    func theProgramIsAWindowsProgram() throws {
        let program = try #require(Data(base64Encoded: WineDisplayMode.programBase64, options: .ignoreUnknownCharacters))
        #expect(program.prefix(2) == Data("MZ".utf8))
        // The PE header's offset is at 0x3c; the machine, i386, follows "PE\0\0".
        let offset = Int(program[0x3c]) | Int(program[0x3d]) << 8
        try #require(program.count > offset + 6)
        #expect(program[offset..<offset + 4] == Data([0x50, 0x45, 0, 0]))
        #expect(program[offset + 4] == 0x4c && program[offset + 5] == 0x01)
    }
}
