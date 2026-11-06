//
//  AllegroPackfile.swift
//  WindowsFormats
//
//  The files an Allegro 4 game writes with pack_fopen(…, "wp"): its
//  settings and high scores, as Icy Tower's tower.cfg. A packed file is
//  `slh!` (F_PACK_MAGIC) and Allegro's LZSS; an unpacked one, which
//  pack_fopen's "rp" reads as well, is `slh.` (F_NOPACK_MAGIC) and the
//  bytes as they are.

import Foundation

/// An Allegro 4 packfile's contents, read and written again.
///
/// Allegro's LZSS (src/lzss.c): a ring of 4096 bytes, starting at 4078
/// (N - F, F = 18) and filled with zeros. Each flags byte says, from its
/// lowest bit up, whether each of the next eight items is a byte as it is
/// (1) or a reference to the ring (0): two bytes, the position (12 bits)
/// and the length less three (4 bits). The stream ends where the file does.
nonisolated public enum AllegroPackfile {
    public static let packedMagic = Data("slh!".utf8)
    public static let unpackedMagic = Data("slh.".utf8)

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// It starts with neither magic.
        case notAPackfile
        /// The packed stream ends partway through a reference.
        case truncated(at: Int)

        public var description: String {
            switch self {
            case .notAPackfile: "it isn't an Allegro packfile (it doesn't start with slh! or slh.)"
            case .truncated(let offset): "its packed data ends partway through an item, at byte \(offset)"
            }
        }
    }

    /// What `file` holds, and whether it was packed.
    public static func read(_ file: Data) throws(Error) -> (contents: Data, packed: Bool) {
        let bytes = [UInt8](file)
        guard bytes.count >= 4 else { throw .notAPackfile }
        let magic = Data(bytes[0..<4])
        if magic == unpackedMagic { return (Data(bytes[4...]), false) }
        guard magic == packedMagic else { throw .notAPackfile }
        return (try unpack(bytes, from: 4), true)
    }

    /// `contents` as a packfile: packed, as the game writes it, or not.
    /// Packed, every byte is written as it is (a flags byte of 0xFF before
    /// each eight), which Allegro reads as it reads its own.
    public static func write(_ contents: Data, packed: Bool) -> Data {
        guard packed else { return unpackedMagic + contents }
        var out = packedMagic
        let bytes = [UInt8](contents)
        var index = 0
        while index < bytes.count {
            let group = bytes[index..<min(index + 8, bytes.count)]
            out.append(UInt8(truncatingIfNeeded: (1 << group.count) - 1))
            out.append(contentsOf: group)
            index += group.count
        }
        return out
    }

    private static let ringSize = 4096
    private static let longest = 18
    private static let threshold = 2

    private static func unpack(_ bytes: [UInt8], from start: Int) throws(Error) -> Data {
        var ring = [UInt8](repeating: 0, count: ringSize)
        var position = ringSize - longest
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        var index = start
        while index < bytes.count {
            let flags = bytes[index]
            index += 1
            for bit in 0..<8 where index < bytes.count {
                if flags & (1 << UInt8(bit)) != 0 {
                    let byte = bytes[index]
                    index += 1
                    out.append(byte)
                    ring[position] = byte
                    position = (position + 1) & (ringSize - 1)
                } else {
                    guard index + 1 < bytes.count else { throw .truncated(at: index) }
                    let low = Int(bytes[index]), high = Int(bytes[index + 1])
                    index += 2
                    let from = low | (high & 0xF0) << 4
                    let length = (high & 0x0F) + threshold + 1
                    for step in 0..<length {
                        let byte = ring[(from + step) & (ringSize - 1)]
                        out.append(byte)
                        ring[position] = byte
                        position = (position + 1) & (ringSize - 1)
                    }
                }
            }
        }
        return Data(out)
    }
}
