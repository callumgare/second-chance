//
//  GameGraphicsAPITests.swift
//  SecondChanceTests
//
//  Reading what a game draws with from its .exe's imports, and arming cursor
//  lock only where cnc-ddraw may be drawing.

import Foundation
import Testing
@testable import SecondChance

@Suite("Game graphics API")
struct GameGraphicsAPITests {
    /// A minimal PE32 image: one section holding an import directory that
    /// names `dlls`.
    static func peImage(importing dlls: [String], magic: UInt16 = 0x10B) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put16(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8(value >> 8 & 0xFF)
        }
        func put32(_ value: Int, at offset: Int) {
            put16(value & 0xFFFF, at: offset)
            put16(value >> 16 & 0xFFFF, at: offset + 2)
        }
        let pe = 0x40, optional = pe + 24
        let optionalSize = magic == 0x10B ? 224 : 240
        let directories = optional + (magic == 0x10B ? 96 : 112)
        let section = optional + optionalSize
        let sectionRVA = 0x1000, sectionFileOffset = 0x200

        put16(0x5A4D, at: 0)  // MZ
        put32(pe, at: 0x3C)
        put32(0x0000_4550, at: pe)  // PE\0\0
        put16(1, at: pe + 6)  // one section
        put16(optionalSize, at: pe + 20)
        put16(Int(magic), at: optional)
        put32(16, at: directories - 4)  // NumberOfRvaAndSizes
        put32(sectionRVA, at: directories + 8)  // the import directory

        put32(0x200, at: section + 8)  // VirtualSize
        put32(sectionRVA, at: section + 12)
        put32(0x200, at: section + 16)  // SizeOfRawData
        put32(sectionFileOffset, at: section + 20)

        // Descriptors first (and a zero one to end them), then the names.
        var nameOffset = (dlls.count + 1) * 20
        for (index, dll) in dlls.enumerated() {
            let descriptor = sectionFileOffset + index * 20
            put32(sectionRVA + nameOffset, at: descriptor + 12)
            put32(0x1F0, at: descriptor + 16)  // FirstThunk: anything non-zero
            for (i, byte) in dll.utf8.enumerated() { bytes[sectionFileOffset + nameOffset + i] = byte }
            nameOffset += dll.utf8.count + 1
        }
        return Data(bytes)
    }

    @Test("An .exe's imports are read, lower-cased", arguments: [UInt16(0x10B), 0x20B])
    func readsImports(magic: UInt16) {
        let image = Self.peImage(importing: ["KERNEL32.dll", "DDRAW.dll", "dsound.dll"], magic: magic)
        #expect(WindowsExecutable.importedDLLs(in: image) == ["kernel32.dll", "ddraw.dll", "dsound.dll"])
    }

    @Test("Something that isn't a PE image has no imports to read")
    func rejectsNonPE() {
        #expect(WindowsExecutable.importedDLLs(in: Data("#!/bin/sh\n".utf8)) == nil)
        #expect(WindowsExecutable.importedDLLs(in: Data()) == nil)
        #expect(WindowsExecutable.importedDLLs(at: URL(fileURLWithPath: "/nonexistent/Game.exe")) == nil)
    }

    // The imports of real Nancy Drew games: the DirectDraw ones up to Shadow
    // Ranch and Blue Moon Canyon, the Direct3D ones from Crystal Skull on —
    // Ghost of Thornton Hall's Steam copy importing steam_api.dll too.
    @Test("What a game draws with follows its imports", arguments: [
        (["kernel32.dll", "ddraw.dll", "dsound.dll", "binkw32.dll"], GameGraphicsAPI.directDraw),
        (["kernel32.dll", "d3d9.dll", "d3dx9_33.dll", "dsound.dll"], .direct3D),
        (["kernel32.dll", "d3d9.dll", "steam_api.dll", "dsound.dll"], .direct3D),
        (["kernel32.dll", "d3d8.dll"], .direct3D),
        (["kernel32.dll", "ddraw.dll", "d3d9.dll"], .directDraw),
        (["kernel32.dll", "d3dx9_33.dll"], .unknown),
        (["kernel32.dll", "user32.dll"], .unknown),
    ])
    func classifiesImports(imports: [String], expected: GameGraphicsAPI) {
        #expect(GameGraphicsAPI(importedDLLs: Set(imports)) == expected)
    }

    @Test("Cursor lock arms unless the game draws with Direct3D")
    func armsCursorLockWhereCncDdrawMayDraw() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameGraphicsAPITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let directDraw = directory.appendingPathComponent("Game.exe")
        try Self.peImage(importing: ["kernel32.dll", "ddraw.dll"]).write(to: directDraw)
        let direct3D = directory.appendingPathComponent("Secrets.exe")
        try Self.peImage(importing: ["kernel32.dll", "d3d9.dll"]).write(to: direct3D)
        let missing = directory.appendingPathComponent("Missing.exe")

        #expect(WineEnvironment.inProcessHelperVariables(gameExe: directDraw, environment: [:])["CURSOR_LOCK_EXE"] == "Game.exe")
        #expect(WineEnvironment.inProcessHelperVariables(gameExe: missing, environment: [:])["CURSOR_LOCK_EXE"] == "Missing.exe")
        let d3dVariables = WineEnvironment.inProcessHelperVariables(gameExe: direct3D, environment: [:])
        #expect(d3dVariables["CURSOR_LOCK_EXE"] == nil)
        // The other helpers don't depend on it.
        #expect(d3dVariables["NATIVE_MACOS_FULLSCREEN_EXE"] == "Secrets.exe")
    }
}
