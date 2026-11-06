import Foundation
import Testing
@testable import WrappBuilder

struct MacROMsTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A ROM is known by the checksum it starts with, kept by its hash, and found again")
    func keepsAKnownROM() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = root.appendingPathComponent("quadra.rom")
        try (Data([0xF1, 0xAC, 0xAD, 0x13]) + Data(count: 1020)).write(to: rom)
        #expect(MacROMs.identify(rom)?.checksum == 0xF1ACAD13)
        #expect(MacROMs.kept(in: root) == nil)
        let kept = try MacROMs.keep(rom, in: root)
        #expect(kept.deletingLastPathComponent() == MacROMs.folder(in: root))
        #expect(kept.pathExtension == "rom" && kept.lastPathComponent.count == 64 + 4)
        #expect(MacROMs.kept(in: root) == kept)
    }

    @Test("A file that isn't a ROM it knows is refused, and never kept")
    func refusesAnythingElse() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other.rom")
        try Data([1, 2, 3, 4, 5]).write(to: other)
        #expect(MacROMs.identify(other) == nil)
        #expect(throws: EngineError.self) { try MacROMs.keep(other, in: root) }
        #expect(MacROMs.kept(in: root) == nil)
    }
}
