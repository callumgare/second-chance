//
//  ISO9660.swift
//  ProgramImages
//
//  A CD's ISO 9660 file system, read in user space rather than mounted: the
//  primary volume descriptor at sector 16, or the Joliet supplementary one
//  (UCS-2 names, so long names survive) when there is one, then directory
//  records from the root down. ECMA-119 has the layout. A raw image
//  (BIN/CUE, 2352-byte sectors) is read through `RawSectorSource`, which
//  presents its 2048-byte user data. Every read is bounds-checked, every
//  walk capped and loops are refused.

import ClassicMacFormats
import Foundation

nonisolated public struct ISO9660: Sendable {
    public struct Entry: Sendable {
        /// From the root: `SETUP/DATA1.CAB`.
        public let path: String
        public let isDirectory: Bool
        /// An associated file: on a hybrid Mac disc, the resource fork of
        /// the file of the same name.
        public let isAssociated: Bool
        /// In bytes, from the start of the source.
        public let offset: Int
        public let length: Int
    }

    public let volumeName: String
    public let isJoliet: Bool
    private let source: any ByteSource
    private let blockSize: Int
    private let root: (extent: Int, length: Int)

    /// Nil if `source` has no ISO 9660 volume descriptor.
    public init?(source: any ByteSource) {
        var primary: Data?
        var joliet: Data?
        for sector in 16..<64 {
            guard let descriptor = source.read((sector * 2048)..<(sector * 2048 + 2048)),
                  descriptor.subdata(checked: 1..<6) == Data("CD001".utf8), let type = descriptor.be8(at: 0) else { break }
            if type == 1, primary == nil { primary = descriptor }
            if type == 2, let escape = descriptor.subdata(checked: 88..<91),
               [Data("%/@".utf8), Data("%/C".utf8), Data("%/E".utf8)].contains(escape) { joliet = descriptor }
            if type == 255 { break }
        }
        guard let descriptor = joliet ?? primary, let blockSize = descriptor.u16le(at: 128),
              [512, 1024, 2048].contains(blockSize),
              let extent = descriptor.u32le(at: 156 + 2), let length = descriptor.u32le(at: 156 + 10) else { return nil }
        self.source = source
        self.blockSize = blockSize
        isJoliet = joliet != nil
        root = (extent, length)
        let name = descriptor.subdata(checked: 40..<72) ?? Data()
        volumeName = (isJoliet ? Self.ucs2(name) : String(decoding: name, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    /// Whether `source` looks like an ISO 9660 image, without reading its tree.
    public static func looksLike(_ source: any ByteSource) -> Bool {
        source.read(0x8001..<0x8006) == Data("CD001".utf8)
    }

    /// Every file and folder, depth first. Up to `limit`.
    public func entries(limit: Int = 200_000) -> [Entry] {
        var entries: [Entry] = []
        var visited: Set<Int> = []
        var stack: [(extent: Int, length: Int, path: String, depth: Int)] = [(root.extent, root.length, "", 0)]
        while let directory = stack.popLast(), entries.count < limit {
            guard directory.depth < 32, visited.insert(directory.extent).inserted, directory.length < 64 << 20,
                  let bytes = source.read((directory.extent * blockSize)..<(directory.extent * blockSize + directory.length))
            else { continue }
            var at = 0
            var children: [(extent: Int, length: Int, path: String, depth: Int)] = []
            while at < bytes.count, entries.count < limit {
                guard let recordLength = bytes.be8(at: at) else { break }
                if recordLength == 0 {
                    // Records don't cross sectors: on to the next.
                    at = (at / 2048 + 1) * 2048
                    continue
                }
                defer { at += recordLength }
                guard recordLength >= 34, let extent = bytes.u32le(at: at + 2), let length = bytes.u32le(at: at + 10),
                      let flags = bytes.be8(at: at + 25), let nameLength = bytes.be8(at: at + 32),
                      let nameBytes = bytes.subdata(checked: (at + 33)..<(at + 33 + nameLength)) else { continue }
                // "." and "..".
                if nameLength == 1, nameBytes.first == 0 || nameBytes.first == 1 { continue }
                var name = isJoliet ? Self.ucs2(nameBytes) : String(decoding: nameBytes, as: UTF8.self)
                if let semicolon = name.lastIndex(of: ";") { name = String(name[..<semicolon]) }
                if !isJoliet, name.hasSuffix("."), flags & 2 == 0 { name.removeLast() }
                name = name.replacingOccurrences(of: "/", with: "_")
                let path = directory.path.isEmpty ? name : directory.path + "/" + name
                let isDirectory = flags & 2 != 0
                entries.append(Entry(path: path, isDirectory: isDirectory, isAssociated: flags & 4 != 0,
                                     offset: extent * blockSize, length: length))
                if isDirectory { children.append((extent, length, path, directory.depth + 1)) }
            }
            stack += children.reversed()
        }
        return entries
    }

    public func read(_ entry: Entry) -> Data? {
        source.read(entry.offset..<(entry.offset + entry.length))
    }

    private static func ucs2(_ data: Data) -> String {
        let units = stride(from: 0, to: data.count - 1, by: 2).compactMap { data.be16(at: $0) }.map(UInt16.init)
        return String(decoding: units, as: UTF16.self)
    }
}

/// A raw CD image (BIN, most MDF and IMG): 2352-byte sectors with a sync
/// pattern and header around 2048 bytes of user data (16 bytes in front for
/// mode 1, 24 for mode 2 form 1). Presented as the 2048-byte sectors the
/// file system was written in.
nonisolated public struct RawSectorSource: ByteSource {
    private let base: any ByteSource
    private let dataOffset: Int
    public let count: Int

    /// Nil unless `base` starts with a sector sync pattern.
    public init?(_ base: any ByteSource) {
        let sync: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        // The first data sector is often after a pregap; the sync is the same.
        guard let head = base.read(0..<16), head.prefix(12).elementsEqual(sync), let mode = head.be8(at: 15),
              mode == 1 || mode == 2 else { return nil }
        self.base = base
        dataOffset = mode == 1 ? 16 : 24
        count = base.count / 2352 * 2048
    }

    public func read(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        var data = Data()
        data.reserveCapacity(range.count)
        var position = range.lowerBound
        while position < range.upperBound {
            let sector = position / 2048
            let within = position % 2048
            let take = min(2048 - within, range.upperBound - position)
            let start = sector * 2352 + dataOffset + within
            guard let bytes = base.read(start..<(start + take)) else { return nil }
            data.append(bytes)
            position += take
        }
        return data
    }
}

extension Data {
    nonisolated func u16le(at offset: Int) -> Int? {
        guard let low = be8(at: offset), let high = be8(at: offset + 1) else { return nil }
        return low | high << 8
    }

    nonisolated func u32le(at offset: Int) -> Int? {
        guard let low = u16le(at: offset), let high = u16le(at: offset + 2) else { return nil }
        return low | high << 16
    }
}
