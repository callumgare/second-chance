//
//  MSISummary.swift
//  SecondChance
//
//  The subject of an MSI's summary information: the game's name, and on
//  Castle Malloy's disc the only place it appears. An MSI is an OLE compound
//  file (MS-CFB) and its summary information a property set stream inside it
//  (MS-OLEPS); this reads just enough of both to find the subject. Every read
//  is bounds-checked and every chain capped, so a damaged file gives nil, never
//  a crash or a hang.

import Foundation
import SecondChanceKit

nonisolated struct MSISummary: Sendable {
    /// PIDSI_SUBJECT, which an MSI sets to the product's name.
    let subject: String?

    /// Mapped rather than read in, since an MSI can be large. Nil if it isn't
    /// a compound file with summary information.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let file = CompoundFile(data),
              let stream = file.stream(named: "\u{5}SummaryInformation"),
              let properties = PropertySet(summaryInformation: stream) else { return nil }
        subject = properties.string(3)
    }
}

/// An OLE compound file: a little FAT file system of fixed-size sectors.
/// Streams under the mini stream cutoff live in the mini stream, in 64-byte
/// sectors with a FAT of their own.
private nonisolated struct CompoundFile {
    private let bytes: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: [Int]
    private let entries: [Entry]

    private struct Entry {
        let name: String
        /// 2 for a stream, 5 for the root, whose own stream is the mini stream.
        let type: Int
        let start: Int
        let size: Int
    }

    /// The highest sector number; anything above marks the end of a chain or
    /// a free sector.
    private static let maxRegularSector = 0xFFFF_FFF9

    init?(_ bytes: Data) {
        guard bytes.prefix(8).elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
              let sectorShift = bytes.u16(at: 0x1E), sectorShift == 9 || sectorShift == 12,
              let miniSectorShift = bytes.u16(at: 0x20), miniSectorShift == 6,
              let firstDirectorySector = bytes.u32(at: 0x30),
              let miniStreamCutoff = bytes.u32(at: 0x38),
              let firstDIFATSector = bytes.u32(at: 0x44) else { return nil }
        let sectorSize = 1 << sectorShift
        self.bytes = bytes
        self.sectorSize = sectorSize
        miniSectorSize = 1 << miniSectorShift
        self.miniStreamCutoff = miniStreamCutoff
        let sectorCount = bytes.count / sectorSize

        // Where the FAT is: the first 109 of its sectors are listed in the
        // header, the rest in a chain of DIFAT sectors.
        var fatSectors = (0..<109).compactMap { bytes.u32(at: 0x4C + $0 * 4) }
            .filter { $0 <= Self.maxRegularSector }
        var difat = firstDIFATSector
        var difatSectorsRead = 0
        let entriesPerSector = sectorSize / 4
        while difat <= Self.maxRegularSector, difatSectorsRead < sectorCount {
            let offset = (difat + 1) * sectorSize
            fatSectors += (0..<entriesPerSector - 1).compactMap { bytes.u32(at: offset + $0 * 4) }
                .filter { $0 <= Self.maxRegularSector }
            guard let next = bytes.u32(at: offset + sectorSize - 4) else { break }
            difat = next
            difatSectorsRead += 1
        }
        fat = fatSectors.prefix(sectorCount).flatMap { sector in
            (0..<entriesPerSector).map { bytes.u32(at: (sector + 1) * sectorSize + $0 * 4) ?? 0xFFFF_FFFF }
        }

        // The directory: 128-byte entries, the root first.
        guard let directory = Self.read(chain: Self.chain(from: firstDirectorySector, in: fat),
                                        sectorSize: sectorSize, from: bytes) else { return nil }
        entries = stride(from: 0, to: directory.count - 127, by: 128).compactMap { offset in
            guard let nameLength = directory.u16(at: offset + 0x40), nameLength >= 2, nameLength <= 64,
                  let type = directory.u8(at: offset + 0x42),
                  let start = directory.u32(at: offset + 0x74),
                  let size = directory.u32(at: offset + 0x78) else { return nil }
            let units = (0..<(nameLength / 2 - 1)).compactMap { directory.u16(at: offset + $0 * 2) }
            return Entry(name: String(decoding: units.map(UInt16.init), as: UTF16.self),
                         type: type, start: start, size: size)
        }
    }

    /// The contents of the stream called `name`, wherever it lives.
    func stream(named name: String) -> Data? {
        guard let entry = entries.first(where: { $0.type == 2 && $0.name == name }) else { return nil }
        guard entry.size < miniStreamCutoff else {
            return Self.read(chain: Self.chain(from: entry.start, in: fat), sectorSize: sectorSize, from: bytes)?
                .prefix(entry.size)
        }
        guard let root = entries.first, root.type == 5,
              let miniStream = Self.read(chain: Self.chain(from: root.start, in: fat),
                                         sectorSize: sectorSize, from: bytes)?.prefix(root.size),
              let firstMiniFATSector = bytes.u32(at: 0x3C),
              let miniFATBytes = Self.read(chain: Self.chain(from: firstMiniFATSector, in: fat),
                                           sectorSize: sectorSize, from: bytes) else { return nil }
        let miniFAT = (0..<miniFATBytes.count / 4).map { miniFATBytes.u32(at: $0 * 4) ?? 0xFFFF_FFFF }
        return Self.read(chain: Self.chain(from: entry.start, in: miniFAT),
                         sectorSize: miniSectorSize, from: miniStream, afterHeader: false)?.prefix(entry.size)
    }

    /// The sectors of a chain, in order. A chain that loops, or runs off the
    /// FAT, ends there.
    private static func chain(from start: Int, in fat: [Int]) -> [Int] {
        var sectors: [Int] = []
        var sector = start
        while sector <= maxRegularSector, sector < fat.count, sectors.count < fat.count {
            sectors.append(sector)
            sector = fat[sector]
        }
        return sectors
    }

    /// The sectors of `chain` from `data`, one after another. Regular sectors
    /// are counted from after the file's header, which is one sector long;
    /// mini sectors from the start of the mini stream.
    private static func read(chain: [Int], sectorSize: Int, from data: Data, afterHeader: Bool = true) -> Data? {
        let headerSectors = afterHeader ? 1 : 0
        var contents = Data()
        for sector in chain {
            let start = data.startIndex + (sector + headerSectors) * sectorSize
            guard start >= data.startIndex, start + sectorSize <= data.endIndex else { return nil }
            contents.append(data[start..<start + sectorSize])
        }
        return contents
    }
}

/// A summary information property set: a header naming the set, then
/// property IDs with offsets to typed values.
private nonisolated struct PropertySet {
    private let stream: Data
    private let start: Int
    private let offsets: [Int: Int]

    /// FMTID_SummaryInformation, F29F85E0-4FF9-1068-AB91-08002B27B3D9, as stored.
    private static let summaryInformation: [UInt8] = [
        0xE0, 0x85, 0x9F, 0xF2, 0xF9, 0x4F, 0x68, 0x10, 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9,
    ]

    init?(summaryInformation stream: Data) {
        guard stream.u16(at: 0) == 0xFFFE, let setCount = stream.u32(at: 24), setCount >= 1,
              stream.dropFirst(28).prefix(16).elementsEqual(Self.summaryInformation),
              let start = stream.u32(at: 44), let count = stream.u32(at: start + 4) else { return nil }
        var offsets: [Int: Int] = [:]
        for index in 0..<min(count, 1024) {
            guard let id = stream.u32(at: start + 8 + index * 8),
                  let offset = stream.u32(at: start + 12 + index * 8) else { break }
            offsets[id] = start + offset
        }
        self.stream = stream
        self.start = start
        self.offsets = offsets
    }

    /// Property `id` as text: a VT_LPSTR in the set's code page, or a
    /// VT_LPWSTR. Nil if it's missing, empty or something else.
    func string(_ id: Int) -> String? {
        guard let offset = offsets[id], let type = stream.u32(at: offset),
              let length = stream.u32(at: offset + 4) else { return nil }
        let value: String?
        switch type {
        case 0x1E:  // VT_LPSTR: a byte count, then the bytes, NUL-ended
            let text = stream.dropFirst(offset + 8).prefix(min(length, 4096)).prefix { $0 != 0 }
            value = String(data: Data(text), encoding: encoding)
        case 0x1F:  // VT_LPWSTR: a character count, then UTF-16
            let units = (0..<min(length, 4096)).compactMap { stream.u16(at: offset + 8 + $0 * 2) }.prefix { $0 != 0 }
            value = String(decoding: units.map(UInt16.init), as: UTF16.self)
        default:
            value = nil
        }
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The set's code page (property 1, a VT_I2), Windows-1252 without one.
    private var encoding: String.Encoding {
        guard let offset = offsets[1], stream.u32(at: offset) == 2, let codePage = stream.u16(at: offset + 4) else {
            return .windowsCP1252
        }
        let encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        guard encoding != kCFStringEncodingInvalidId else { return .windowsCP1252 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
