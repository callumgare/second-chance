//
//  HFSVolume.swift
//  ClassicMacFormats
//
//  A classic HFS volume ("Mac OS Standard"), read in user space: macOS
//  hasn't mounted one since 10.15, and a disc image shouldn't be mounted to
//  be looked into anyway. The master directory block at 1024 bytes gives the
//  allocation block size and where the extents and catalog files are; the
//  catalog is a B-tree whose leaves hold every folder and file (with its
//  Finder info and its forks' first three extents); the extents overflow
//  B-tree holds the rest of a fragmented fork's extents. Inside Macintosh:
//  Files, chapter 2, has the layout; HFSKit and machfs were the references.
//  Every read is bounds-checked and every walk capped.
//
//  Also the containers HFS volumes come in: an Apple partition map (a CD's
//  Mac side, beside its ISO 9660 one) and Disk Copy 4.2 images.

import Foundation

nonisolated public struct HFSVolume: Sendable {
    public struct Extent: Sendable, Equatable {
        public let start: Int
        public let count: Int
    }

    public struct Entry: Sendable {
        /// Folder names from the root (not including the volume's own
        /// name), then this entry's name.
        public let path: [String]
        public let isDirectory: Bool
        public let id: Int
        public let parentID: Int
        public let type: String
        public let creator: String
        public let finderFlags: Int
        public let dataLength: Int
        public let resourceLength: Int
        fileprivate let dataExtents: [Extent]
        fileprivate let resourceExtents: [Extent]

        public var name: String { path.last ?? "" }
        public var hasCustomIcon: Bool { finderFlags & 0x0400 != 0 }
    }

    public let name: String
    private let source: any ByteSource
    private let blockSize: Int
    /// Where allocation block 0 starts, in bytes.
    private let firstBlock: Int
    private let catalogExtents: [Extent]
    private let catalogLength: Int
    private let extentsExtents: [Extent]
    private let extentsLength: Int

    /// Nil if there is no HFS master directory block at 1024 bytes.
    public init?(source: any ByteSource) {
        guard let mdb = source.read(1024..<1536), mdb.be16(at: 0) == 0x4244,  // "BD"
              let blockSize = mdb.be32(at: 20), blockSize >= 512, blockSize % 512 == 0,
              let firstSector = mdb.be16(at: 28),
              let name = mdb.pascalString(at: 36, maxLength: 27),
              let extentsLength = mdb.be32(at: 130), let catalogLength = mdb.be32(at: 146) else { return nil }
        self.source = source
        self.name = name
        self.blockSize = blockSize
        firstBlock = firstSector * 512
        self.extentsLength = extentsLength
        extentsExtents = Self.extents(mdb, at: 134)
        self.catalogLength = catalogLength
        catalogExtents = Self.extents(mdb, at: 150)
    }

    /// Whether `source` holds an HFS volume an embedded HFS+ one (a wrapper
    /// whose real volume 7-Zip reads) sits in.
    public static func isHFSPlusWrapper(_ source: any ByteSource) -> Bool {
        source.read(1024..<1536)?.be16(at: 124) == 0x482B  // "H+"
    }

    private static func extents(_ record: Data, at offset: Int) -> [Extent] {
        (0..<3).compactMap { index in
            guard let start = record.be16(at: offset + index * 4), let count = record.be16(at: offset + index * 4 + 2),
                  count > 0 else { return nil }
            return Extent(start: start, count: count)
        }
    }

    // MARK: - Entries

    /// Every folder and file, folders' paths worked out from the catalog's
    /// parent IDs. Up to `limit` of them.
    public func entries(limit: Int = 200_000) -> [Entry] {
        guard let catalog = readFork(extents: catalogExtents, length: catalogLength, fileID: 4, resource: false)
        else { return [] }
        struct Raw {
            let parentID: Int
            let name: String
            let record: Data
        }
        var raws: [Raw] = []
        Self.walkLeaves(catalog, limit: limit) { key, record in
            guard let parentID = key.be32(at: 1), let name = key.pascalString(at: 5, maxLength: 31) else { return }
            raws.append(Raw(parentID: parentID, name: name, record: record))
        }
        // Folders: ID → (parent, name).
        var folders: [Int: (parent: Int, name: String)] = [:]
        for raw in raws where raw.record.be8(at: 0) == 1 {
            if let id = raw.record.be32(at: 6) { folders[id] = (raw.parentID, raw.name) }
        }
        func path(of parent: Int) -> [String]? {
            var names: [String] = []
            var id = parent
            var steps = 0
            while id != 2 {  // the root folder
                guard let folder = folders[id], steps < 128 else { return nil }
                names.append(folder.name)
                id = folder.parent
                steps += 1
            }
            return names.reversed()
        }
        var entries: [Entry] = []
        for raw in raws {
            let record = raw.record
            guard let kind = record.be8(at: 0), kind == 1 || kind == 2,
                  raw.parentID != 1,  // the root folder's own record
                  let parentPath = path(of: raw.parentID) else { continue }
            if kind == 1 {
                guard let id = record.be32(at: 6) else { continue }
                entries.append(Entry(path: parentPath + [raw.name], isDirectory: true, id: id, parentID: raw.parentID,
                                     type: "", creator: "", finderFlags: record.be16(at: 30) ?? 0, dataLength: 0,
                                     resourceLength: 0, dataExtents: [], resourceExtents: []))
            } else {
                guard let id = record.be32(at: 20), let dataLength = record.be32(at: 26),
                      let resourceLength = record.be32(at: 36) else { continue }
                entries.append(Entry(path: parentPath + [raw.name], isDirectory: false, id: id, parentID: raw.parentID,
                                     type: record.osType(at: 4) ?? "", creator: record.osType(at: 8) ?? "",
                                     finderFlags: record.be16(at: 12) ?? 0, dataLength: dataLength,
                                     resourceLength: resourceLength, dataExtents: Self.extents(record, at: 74),
                                     resourceExtents: Self.extents(record, at: 86)))
            }
        }
        return entries
    }

    /// A file's data fork; nil if it can't be read whole.
    public func dataFork(of entry: Entry) -> Data? {
        readFork(extents: entry.dataExtents, length: entry.dataLength, fileID: entry.id, resource: false)
    }

    public func resourceFork(of entry: Entry) -> Data? {
        readFork(extents: entry.resourceExtents, length: entry.resourceLength, fileID: entry.id, resource: true)
    }

    /// Whether a fork lies in one run of blocks, so it can be read as a
    /// slice rather than copied together.
    public func contiguousRange(of entry: Entry, resource: Bool) -> Range<Int>? {
        let extents = resource ? entry.resourceExtents : entry.dataExtents
        let length = resource ? entry.resourceLength : entry.dataLength
        guard let first = extents.first, first.count * blockSize >= length else { return nil }
        let start = firstBlock + first.start * blockSize
        return start..<(start + length)
    }

    // MARK: - Reading forks

    private func readFork(extents first: [Extent], length: Int, fileID: Int, resource: Bool) -> Data? {
        guard length > 0 else { return Data() }
        guard length <= 1 << 31 else { return nil }
        var extents = first
        var covered = extents.reduce(0) { $0 + $1.count }
        let needed = (length + blockSize - 1) / blockSize
        // The rest from the extents overflow file, keyed by the block they start at.
        if covered < needed, fileID != 3 {
            let overflow = overflowExtents()
            var guardCount = 0
            while covered < needed, guardCount < 1000,
                  let more = overflow[OverflowKey(resource: resource, fileID: fileID, start: covered)] {
                extents += more
                covered += more.reduce(0) { $0 + $1.count }
                guardCount += 1
            }
        }
        guard covered >= needed else { return nil }
        var fork = Data()
        fork.reserveCapacity(length)
        for extent in extents where fork.count < length {
            let start = firstBlock + extent.start * blockSize
            let take = min(extent.count * blockSize, length - fork.count)
            guard let bytes = source.read(start..<(start + take)) else { return nil }
            fork.append(bytes)
        }
        return fork.count == length ? fork : nil
    }

    private struct OverflowKey: Hashable {
        let resource: Bool
        let fileID: Int
        let start: Int
    }

    private func overflowExtents() -> [OverflowKey: [Extent]] {
        guard let file = readFork(extents: extentsExtents, length: extentsLength, fileID: 3, resource: false)
        else { return [:] }
        var map: [OverflowKey: [Extent]] = [:]
        Self.walkLeaves(file, limit: 100_000) { key, record in
            guard let fork = key.be8(at: 0), let fileID = key.be32(at: 1), let start = key.be16(at: 5) else { return }
            map[OverflowKey(resource: fork == 0xFF, fileID: fileID, start: start)] = Self.extents(record, at: 0)
        }
        return map
    }

    /// Every record in a B-tree's leaves, first leaf to last, as its key
    /// (without the length byte: the catalog's is a reserved byte, the
    /// parent's ID and the name) and its data.
    private static func walkLeaves(_ tree: Data, limit: Int, _ visit: (Data, Data) -> Void) {
        guard let nodeSize = tree.be16(at: 14 + 18), nodeSize >= 512, nodeSize <= 32768,
              var node = tree.be32(at: 14 + 10) else { return }
        var visited = 0
        var records = 0
        let nodeCount = tree.count / nodeSize
        while node != 0, node < nodeCount, visited < nodeCount, records < limit {
            visited += 1
            let base = node * nodeSize
            guard let bytes = tree.subdata(checked: base..<(base + nodeSize)), bytes.be8(at: 8) == 0xFF,  // a leaf
                  let count = bytes.be16(at: 10) else { break }
            for index in 0..<min(count, nodeSize / 2) {
                guard let offset = bytes.be16(at: nodeSize - 2 * (index + 1)), let keyLength = bytes.be8(at: offset),
                      keyLength > 0 else { continue }
                let dataStart = (offset + 1 + keyLength + 1) & ~1
                guard dataStart <= nodeSize, let key = bytes.subdata(checked: (offset + 1)..<(offset + 1 + keyLength)),
                      let record = bytes.subdata(checked: dataStart..<nodeSize) else { continue }
                visit(Data(key), Data(record))
                records += 1
            }
            node = bytes.be32(at: 0) ?? 0
        }
    }
}

// MARK: - Apple partition map

nonisolated public struct ApplePartitionMap: Sendable {
    public struct Partition: Sendable {
        public let name: String
        public let type: String
        public let offset: Int
        public let length: Int
    }

    public let partitions: [Partition]

    /// Nil if `source` doesn't start with a partition map. Entries are
    /// 512-byte records counted in the driver descriptor's block size or in
    /// 512-byte blocks, as discs differ; both are tried.
    public init?(source: any ByteSource) {
        guard let head = source.read(0..<512), head.be16(at: 0) == 0x4552 else { return nil }  // "ER"
        let declared = head.be16(at: 2) ?? 512
        for blockSize in Array(Set([declared, 512])).sorted(by: >) where blockSize >= 512 && blockSize <= 4096 {
            var partitions: [Partition] = []
            var index = 1
            var count = 1
            while index <= count, index < 64,
                  let entry = source.read((index * blockSize)..<(index * blockSize + 512)), entry.be16(at: 0) == 0x504D {
                count = entry.be32(at: 4) ?? 0
                if let start = entry.be32(at: 8), let blocks = entry.be32(at: 12) {
                    let name = entry.subdata(checked: 16..<48).map { MacRoman.string($0.prefix { $0 != 0 }) } ?? ""
                    let type = entry.subdata(checked: 48..<80).map { MacRoman.string($0.prefix { $0 != 0 }) } ?? ""
                    partitions.append(Partition(name: name, type: type, offset: start * blockSize,
                                                length: blocks * blockSize))
                }
                index += 1
            }
            if !partitions.isEmpty {
                self.partitions = partitions
                return
            }
        }
        return nil
    }
}

// MARK: - Disk Copy 4.2

nonisolated public enum DiskCopy42 {
    /// The volume's bytes in a Disk Copy 4.2 image (an 84-byte header, then
    /// the disk); nil if `source` isn't one.
    public static func volume(in source: any ByteSource) -> ByteSlice? {
        guard let header = source.read(0..<84), header.be16(at: 82) == 0x0100,
              let nameLength = header.be8(at: 0), nameLength < 64,
              let dataSize = header.be32(at: 64), dataSize > 0, 84 + dataSize <= source.count else { return nil }
        return ByteSlice(source, offset: 84, count: dataSize)
    }
}
