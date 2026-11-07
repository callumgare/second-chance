//
//  MacROMQuestionTests.swift
//  SecondChanceTests
//
//  The ROM a basilisk game's Mac boots: given by MAC_ROM_PATH, checked and
//  kept in the engine store, and never asked for with no one to ask.

import Foundation
import Testing
@testable import SecondChance
import WrappBuilder

@Suite("A Mac's ROM for the build")
@MainActor
struct MacROMQuestionTests {
    /// A file a ROM's checksum starts, an F1ACAD13 (a Quadra 800's).
    func fakeROM(in folder: URL) throws -> URL {
        let rom = folder.appendingPathComponent("800.ROM")
        try (Data([0xF1, 0xAC, 0xAD, 0x13]) + Data(repeating: 0, count: 1020)).write(to: rom)
        return rom
    }

    @Test("MAC_ROM_PATH's ROM is checked and kept in the engine store, where later builds find it")
    func givenByEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacROMQuestionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(in: root)
        let engines = EngineStore(root: root.appendingPathComponent("engines"),
                                  preparer: EnginePreparer(downloader: DownloadWrappBuilder.standardDownloader()))
        let helper = WrappBuildHelper(engines: engines, bus: EventBus<AppEvent>())
        let input = WrappBuildInput(environment: ["MAC_ROM_PATH": rom.path, "NON_INTERACTIVE": "true"], viewModel: nil)
        try await helper.ensureMacROM(input: input)
        let kept = try #require(MacROMs.kept(in: engines.root))
        #expect(try Data(contentsOf: kept) == Data(contentsOf: rom))
    }

    @Test("With no one to ask and no MAC_ROM_PATH, nothing is asked")
    func noOneToAsk() async throws {
        let input = WrappBuildInput(environment: ["NON_INTERACTIVE": "true"], viewModel: nil)
        #expect(try await input.getMacROM() == nil)
        #expect(try await input.getMacROM(asking: false) == nil)
        let given = WrappBuildInput(environment: ["MAC_ROM_PATH": "/tmp/x.rom"], viewModel: nil)
        #expect(try await given.getMacROM(asking: false)?.path == "/tmp/x.rom")
        // A file that wasn't one isn't given again.
        #expect(try await given.getMacROM(rejected: URL(fileURLWithPath: "/tmp/x.rom"), asking: false) == nil)
    }
}
