//
//  MacROMs.swift
//  WrappBuilder
//
//  The ROMs of old Macs that the basilisk module's emulator boots, which
//  Apple never gave out: the person's own, kept in the engine store.

import CryptoKit
import Foundation

/// A classic Mac's ROM, which Basilisk II needs to run a Mac, and which no
/// module may ship: given once by the person (or, in a Debug build of Second
/// Chance, downloaded: `WrappBuildHelper.ensureMacROM`), checked by the checksum in its first four bytes, and kept in
/// the engine store beside the prepared engines (`roms/<sha256>.rom`), where
/// every later build finds it (`module:basilisk:/rom`).
public nonisolated enum MacROMs {
    /// The ROMs Basilisk II runs well, by their checksum, and the Macs they
    /// came from, as a person would know them.
    public static let known: [UInt32: String] = [
        0xF1ACAD13: "a Quadra 650 or 800, or a Centris 650",
    ]

    /// What `module:basilisk:/rom` names.
    public static let providedFile = "module:basilisk:/rom"

    /// Where an engine store at `root` keeps ROMs.
    public static func folder(in root: URL) -> URL { root.appendingPathComponent("roms", isDirectory: true) }

    /// The checksum a ROM file starts with, and the Mac it's from; nil for
    /// a file that isn't a ROM Basilisk II runs.
    public static func identify(_ file: URL) -> (checksum: UInt32, mac: String)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        let checksum = head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return known[checksum].map { (checksum, $0) }
    }

    /// A ROM kept in the store at `root`, the first that's still one it
    /// knows; nil when there's none.
    public static func kept(in root: URL) -> URL? {
        let folder = folder(in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".rom") }.sorted()
            .map { folder.appendingPathComponent($0) }
            .first { identify($0) != nil }
    }

    /// `file` checked and kept in the store at `root`, as `<sha256>.rom`.
    /// Throws, saying so plainly, for a file that isn't a ROM it can use.
    @discardableResult
    public static func keep(_ file: URL, in root: URL) throws -> URL {
        guard identify(file) != nil else {
            throw EngineError("\(file.lastPathComponent) isn't the ROM of a Mac this can run")
        }
        let data = try Data(contentsOf: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appendingPathComponent("\(hash).rom")
        if !FileManager.default.fileExists(atPath: kept.path) {
            // Written whole, then moved into place: no build sees half a ROM.
            let partial = folder.appendingPathComponent(".\(hash).partial")
            try data.write(to: partial)
            try FileManager.default.moveItem(at: partial, to: kept)
        }
        return kept
    }
}
