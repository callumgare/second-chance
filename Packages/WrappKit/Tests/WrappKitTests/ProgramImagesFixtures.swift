//
//  ProgramImagesFixtures.swift
//  WrappKitTests
//
//  Tiny files of every format ProgramImages reads, built byte by byte so the
//  tests need no real (copyrighted) program, disc or icon: DIB icons, PE and
//  NE programs with resources, shortcuts, resource forks with icon families
//  and bundles, MacBinary, AppleSingle, BinHex, ISO 9660 and HFS volumes.

import Foundation

enum Fixture {
    // MARK: - Byte helpers

    static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    static func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
    static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { be16((value >> 16) & 0xFFFF) + be16(value & 0xFFFF) }
    static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
    static func pascal(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + ascii(text) }
    static func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    static func put(_ bytes: [UInt8], into buffer: inout [UInt8], at offset: Int) {
        if buffer.count < offset + bytes.count { buffer += [UInt8](repeating: 0, count: offset + bytes.count - buffer.count) }
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    // MARK: - Windows icons and bitmaps

    /// A `size`×`size` 4-bit icon image (DIB + AND mask): palette entry 1
    /// (red) in the top-left quarter, entry 2 (blue) elsewhere, and the
    /// bottom-right pixel see-through.
    static func dibIcon4(size: Int = 16) -> [UInt8] {
        var bytes = le32(40) + le32(size) + le32(size * 2) + le16(1) + le16(4) + le32(0) + le32(0)
            + le32(0) + le32(0) + le32(16) + le32(0)
        // Palette: BGRx.
        var palette = [UInt8](repeating: 0, count: 64)
        palette.replaceSubrange(4..<8, with: [0, 0, 255, 0])  // 1: red
        palette.replaceSubrange(8..<12, with: [255, 0, 0, 0])  // 2: blue
        bytes += palette
        let rowBytes = ((size * 4 + 31) / 32) * 4
        // Rows bottom up.
        for row in (0..<size).reversed() {
            var line = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<size {
                let index = row < size / 2 && x < size / 2 ? 1 : 2
                line[x / 2] |= UInt8(x % 2 == 0 ? index << 4 : index)
            }
            bytes += line
        }
        let maskRowBytes = ((size + 31) / 32) * 4
        for row in (0..<size).reversed() {
            var line = [UInt8](repeating: 0, count: maskRowBytes)
            if row == size - 1 { line[(size - 1) / 8] |= UInt8(1 << (7 - (size - 1) % 8)) }
            bytes += line
        }
        return bytes
    }

    /// A 24-bit `width`×`height` DIB (an RT_BITMAP), all one colour but a
    /// green first column.
    static func dib24(width: Int, height: Int) -> [UInt8] {
        var bytes = le32(40) + le32(width) + le32(height) + le16(1) + le16(24) + le32(0) + le32(0)
            + le32(0) + le32(0) + le32(0) + le32(0)
        let rowBytes = ((width * 24 + 31) / 32) * 4
        for _ in 0..<height {
            var line = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<width {
                line.replaceSubrange((x * 3)..<(x * 3 + 3), with: x == 0 ? [0, 255, 0] : [40, 80, 160])
            }
            bytes += line
        }
        return bytes
    }

    /// An .ico of one image.
    static func ico(_ image: [UInt8], size: Int = 16, bits: Int = 4) -> [UInt8] {
        cat(le16(0), le16(1), le16(1), [UInt8(size), UInt8(size), 16, 0], le16(1), le16(bits),
            le32(image.count), le32(22), image)
    }

    /// A group directory naming RT_ICON `ids`, each a 16×16 4-bit image.
    static func groupIcon(ids: [Int], byteCount: Int) -> [UInt8] {
        var bytes = le16(0) + le16(1) + le16(ids.count)
        for id in ids { bytes += [16, 16, 16, 0] + le16(1) + le16(4) + le32(byteCount) + le16(id) }
        return bytes
    }

    // MARK: - PE

    enum Key: Comparable, Hashable {
        case name(String)
        case id(Int)
    }

    struct Resource {
        let type: Key
        let name: Key
        let data: [UInt8]
    }

    /// A PE image with one section, `.rsrc`, holding `resources`, and
    /// `overlay` after it.
    static func pe(resources: [Resource], overlay: [UInt8] = [], sectionNames: [String] = [".rsrc"]) -> Data {
        let pe = 0x40, optional = pe + 24, optionalSize = 224
        let directories = optional + 96
        let section = optional + optionalSize
        let sectionRVA = 0x1000, fileOffset = 0x400
        var header = [UInt8](repeating: 0, count: fileOffset)
        put(le16(0x5A4D), into: &header, at: 0)
        put(le32(pe), into: &header, at: 0x3C)
        put(le32(0x4550), into: &header, at: pe)
        put(le16(sectionNames.count), into: &header, at: pe + 6)
        put(le16(optionalSize), into: &header, at: pe + 20)
        put(le16(0x10B), into: &header, at: optional)
        put(le16(2), into: &header, at: optional + 68)  // Windows GUI
        put(le32(16), into: &header, at: directories - 4)
        put(le32(sectionRVA), into: &header, at: directories + 2 * 8)

        let rsrc = resourceSection(resources, rva: sectionRVA)
        let rawSize = (rsrc.count + 511) & ~511
        for (index, name) in sectionNames.enumerated() {
            let at = section + index * 40
            put(Array(name.utf8.prefix(8)), into: &header, at: at)
            put(le32(index == 0 ? rsrc.count : 0), into: &header, at: at + 8)
            put(le32(sectionRVA + index * 0x10_0000), into: &header, at: at + 12)
            put(le32(index == 0 ? rawSize : 0), into: &header, at: at + 16)
            put(le32(fileOffset), into: &header, at: at + 20)
        }
        let body = rsrc + [UInt8](repeating: 0, count: rawSize - rsrc.count)
        return Data(header + body + overlay)
    }

    /// The resource directory: type → name → one language (0x409).
    static func resourceSection(_ resources: [Resource], rva: Int) -> [UInt8] {
        let types = Array(Set(resources.map(\.type))).sorted()
        var byType: [Key: [Resource]] = [:]
        for resource in resources { byType[resource.type, default: []].append(resource) }
        for key in byType.keys { byType[key]?.sort { $0.name < $1.name } }

        // Layout: root, type directories, name directories, data entries, strings, data.
        var offset = 16 + 8 * types.count
        var typeDirectory: [Key: Int] = [:]
        for type in types {
            typeDirectory[type] = offset
            offset += 16 + 8 * (byType[type]?.count ?? 0)
        }
        var nameDirectory: [Int: Int] = [:]  // resource index → offset
        var flat: [Resource] = []
        for type in types { flat += byType[type] ?? [] }
        for index in flat.indices {
            nameDirectory[index] = offset
            offset += 16 + 8
        }
        var dataEntry: [Int: Int] = [:]
        for index in flat.indices {
            dataEntry[index] = offset
            offset += 16
        }
        var strings: [String: Int] = [:]
        var stringBytes: [UInt8] = []
        let allNames = types.compactMap { if case .name(let name) = $0 { name } else { nil } }
            + flat.compactMap { if case .name(let name) = $0.name { name } else { nil } }
        for name in allNames where strings[name] == nil {
            strings[name] = offset + stringBytes.count
            stringBytes += le16(name.utf16.count) + name.utf16.flatMap { le16(Int($0)) }
        }
        offset += stringBytes.count
        offset = (offset + 3) & ~3
        var dataOffset: [Int: Int] = [:]
        var blobs: [UInt8] = []
        for (index, resource) in flat.enumerated() {
            dataOffset[index] = offset + blobs.count
            blobs += resource.data
            while blobs.count % 4 != 0 { blobs.append(0) }
        }

        var bytes = [UInt8](repeating: 0, count: offset)
        func directory(at position: Int, entries: [(Key, Int, Bool)]) {
            let named = entries.filter { if case .name = $0.0 { true } else { false } }.count
            put(le16(named), into: &bytes, at: position + 12)
            put(le16(entries.count - named), into: &bytes, at: position + 14)
            for (index, entry) in entries.enumerated() {
                let at = position + 16 + index * 8
                switch entry.0 {
                case .id(let id): put(le32(id), into: &bytes, at: at)
                case .name(let name): put(le32(0x8000_0000 | (strings[name] ?? 0)), into: &bytes, at: at)
                }
                put(le32(entry.1 | (entry.2 ? 0x8000_0000 : 0)), into: &bytes, at: at + 4)
            }
        }
        directory(at: 0, entries: types.map { ($0, typeDirectory[$0] ?? 0, true) })
        var flatIndex = 0
        for type in types {
            let resources = byType[type] ?? []
            let indices = Array(flatIndex..<(flatIndex + resources.count))
            directory(at: typeDirectory[type] ?? 0,
                      entries: zip(resources, indices).map { ($0.name, nameDirectory[$1] ?? 0, true) })
            flatIndex += resources.count
        }
        for index in flat.indices {
            directory(at: nameDirectory[index] ?? 0, entries: [(.id(0x409), dataEntry[index] ?? 0, false)])
            put(le32(rva + (dataOffset[index] ?? 0)), into: &bytes, at: dataEntry[index] ?? 0)
            put(le32(flat[index].data.count), into: &bytes, at: (dataEntry[index] ?? 0) + 4)
        }
        // Strings sit right after the data entries.
        if let first = strings.values.min() { put(stringBytes, into: &bytes, at: first) }
        return bytes + blobs
    }

    // MARK: - NE

    /// A 16-bit program with an RT_GROUP_ICON (id 1) naming RT_ICON 1.
    static func ne(icon: [UInt8]) -> Data {
        let neOffset = 0x80
        var bytes = [UInt8](repeating: 0, count: neOffset)
        put(le16(0x5A4D), into: &bytes, at: 0)
        put(le32(neOffset), into: &bytes, at: 0x3C)
        var ne = [UInt8](repeating: 0, count: 0x40)
        put(ascii("NE"), into: &ne, at: 0)
        ne[0x36] = 2
        let tableOffset = 0x40
        let group = groupIcon(ids: [1], byteCount: icon.count)
        // Alignment shift 4: data at multiples of 16.
        var table = le16(4)
        let iconStart = 0x200, groupStart = 0x400
        table += le16(0x8003) + le16(1) + le32(0)
        table += le16(iconStart >> 4) + le16((icon.count + 15) >> 4) + le16(0x30) + le16(0x8001) + le32(0)
        table += le16(0x800E) + le16(1) + le32(0)
        table += le16(groupStart >> 4) + le16((group.count + 15) >> 4) + le16(0x30) + le16(0x8001) + le32(0)
        table += le16(0)
        put(le16(tableOffset), into: &ne, at: 0x24)
        put(le16(tableOffset + table.count), into: &ne, at: 0x26)  // resident names after
        bytes += ne + table + pascal("TESTMOD") + [0]
        put(icon, into: &bytes, at: iconStart)
        put(group, into: &bytes, at: groupStart)
        return Data(bytes)
    }

    // MARK: - Shortcuts

    /// A Unicode shell link to `target` with LinkInfo, and an icon location.
    static func shellLink(target: String, icon: String?, iconIndex: Int = 0) -> Data {
        var flags = 0x02 | 0x80
        if icon != nil { flags |= 0x40 }
        var bytes = le32(0x4C) + [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46] + le32(flags)
        bytes += [UInt8](repeating: 0, count: 0x38 - bytes.count)
        bytes += le32(iconIndex) + le32(1) + [UInt8](repeating: 0, count: 0x4C - 0x40)
        // LinkInfo: header 0x1C, local base path after it, an empty suffix.
        let base = ascii(target) + [0]
        let infoSize = 0x1C + base.count + 1
        bytes += le32(infoSize) + le32(0x1C) + le32(1) + le32(0) + le32(0x1C) + le32(0) + le32(0x1C + base.count)
        bytes += base + [0]
        if let icon {
            bytes += le16(icon.utf16.count) + icon.utf16.flatMap { le16(Int($0)) }
        }
        return Data(bytes + le32(0))
    }

    // MARK: - Classic Mac

    /// A resource fork of `resources` (type, ID, name, data).
    static func resourceFork(_ resources: [(type: String, id: Int, name: String?, data: [UInt8])]) -> [UInt8] {
        var data: [UInt8] = []
        var dataOffsets: [Int] = []
        for resource in resources {
            dataOffsets.append(data.count)
            data += be32(resource.data.count) + resource.data
        }
        var types: [String] = []
        for resource in resources where !types.contains(resource.type) { types.append(resource.type) }
        var names: [UInt8] = []
        var typeList = be16(types.count - 1)
        var references: [UInt8] = []
        let referenceStart = 2 + types.count * 8
        for type in types {
            let members = resources.indices.filter { resources[$0].type == type }
            typeList += ascii(type) + be16(members.count - 1) + be16(referenceStart + references.count)
            for index in members {
                var nameOffset = 0xFFFF
                if let name = resources[index].name {
                    nameOffset = names.count
                    names += pascal(name)
                }
                references += be16(resources[index].id & 0xFFFF) + be16(nameOffset) + be32(dataOffsets[index]) + be32(0)
            }
        }
        let mapHeader = 28
        let map = [UInt8](repeating: 0, count: 24) + be16(mapHeader) + be16(mapHeader + typeList.count + references.count)
            + typeList + references + names
        let dataOffset = 256
        let mapOffset = dataOffset + data.count
        var fork = be32(dataOffset) + be32(mapOffset) + be32(data.count) + be32(map.count)
        fork += [UInt8](repeating: 0, count: dataOffset - fork.count)
        return fork + data + map
    }

    /// An application's icon family, ID 128, with a bundle pointing to it:
    /// ICN# (a filled square, mask all set) and icl8 (colour 5 everywhere).
    static func applicationFork() -> [UInt8] {
        let icon = [UInt8](repeating: 0xFF, count: 128) + [UInt8](repeating: 0xFF, count: 128)
        let icl8 = [UInt8](repeating: 5, count: 1024)
        let bundle = ascii("TEST") + be16(0) + be16(1)  // two types
            + ascii("ICN#") + be16(0) + be16(0) + be16(128)  // local 0 → ICN# 128
            + ascii("FREF") + be16(0) + be16(0) + be16(128)  // local 0 → FREF 128
        let fref = ascii("APPL") + be16(0) + [0]
        return resourceFork([("ICN#", 128, nil, icon), ("icl8", 128, nil, icl8), ("BNDL", 128, nil, bundle),
                             ("FREF", 128, nil, fref)])
    }

    static func macBinary(name: String, type: String, creator: String, data: [UInt8], resource: [UInt8]) -> Data {
        var header = [UInt8](repeating: 0, count: 128)
        put(pascal(name), into: &header, at: 1)
        put(ascii(type), into: &header, at: 65)
        put(ascii(creator), into: &header, at: 69)
        put(be32(data.count), into: &header, at: 83)
        put(be32(resource.count), into: &header, at: 87)
        func padded(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: (128 - bytes.count % 128) % 128) }
        return Data(header + padded(data) + padded(resource))
    }

    static func appleSingle(type: String, data: [UInt8], resource: [UInt8]) -> Data {
        let finderInfo = ascii(type) + ascii("TEST") + be16(0x0400) + [UInt8](repeating: 0, count: 22)
        let entries = [(1, data), (2, resource), (9, finderInfo)]
        var offset = 26 + entries.count * 12
        var header = be32(0x0005_1600) + be32(0x0002_0000) + [UInt8](repeating: 0, count: 16) + be16(entries.count)
        var body: [UInt8] = []
        for (id, bytes) in entries {
            header += be32(id) + be32(offset) + be32(bytes.count)
            offset += bytes.count
            body += bytes
        }
        return Data(header + body)
    }

    /// BinHex 4.0 of a file (no run-length runs; CRCs left zero).
    static func binHex(name: String, type: String, data: [UInt8], resource: [UInt8]) -> Data {
        var raw = cat(pascal(name), [0], ascii(type), ascii("TEST"), be16(0), be32(data.count), be32(resource.count), [0, 0])
        raw += cat(data, [0, 0], resource, [0, 0])
        // 0x90 is the run marker: written as 0x90 0x00.
        raw = raw.flatMap { (byte: UInt8) -> [UInt8] in byte == 0x90 ? [0x90, 0x00] : [byte] }
        let alphabet = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)
        var text: [UInt8] = []
        var accumulator = 0
        var bits = 0
        for byte in raw {
            accumulator = accumulator << 8 | Int(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                text.append(alphabet[(accumulator >> bits) & 0x3F])
            }
        }
        if bits > 0 { text.append(alphabet[(accumulator << (6 - bits)) & 0x3F]) }
        var lines: [UInt8] = []
        for (index, character) in text.enumerated() {
            if index > 0, index % 64 == 0 { lines.append(0x0A) }
            lines.append(character)
        }
        return Data(ascii("(This file must be converted with BinHex 4.0)\n:") + lines + ascii(":\n"))
    }

    // MARK: - Discs

    /// An ISO 9660 image (no Joliet) of `files` in the root folder.
    static func iso(files: [(name: String, data: [UInt8])], volume: String = "TESTDISC") -> Data {
        let block = 2048
        var image = [UInt8](repeating: 0, count: block * 19)
        func record(name: [UInt8], extent: Int, length: Int, directory: Bool) -> [UInt8] {
            var record = cat([0, 0], le32(extent), be32(extent), le32(length), be32(length),
                             [UInt8](repeating: 0, count: 7), [directory ? 2 : 0, 0, 0], le16(1), be16(1), [UInt8(name.count)], name)
            if record.count % 2 == 1 { record.append(0) }
            record[0] = UInt8(record.count)
            return record
        }
        var dataSector = 19
        var directory = record(name: [0], extent: 18, length: block, directory: true)
            + record(name: [1], extent: 18, length: block, directory: true)
        var payload: [UInt8] = []
        for file in files {
            directory += record(name: ascii(file.name + ";1"), extent: dataSector, length: file.data.count, directory: false)
            var padded = file.data
            padded += [UInt8](repeating: 0, count: (block - padded.count % block) % block)
            if padded.isEmpty { padded = [UInt8](repeating: 0, count: block) }
            payload += padded
            dataSector += padded.count / block
        }
        var pvd = [UInt8](repeating: 0, count: block)
        put([1] + ascii("CD001") + [1], into: &pvd, at: 0)
        put(ascii(volume.padding(toLength: 32, withPad: " ", startingAt: 0)), into: &pvd, at: 40)
        put(le16(block) + be16(block), into: &pvd, at: 128)
        put(record(name: [0], extent: 18, length: block, directory: true), into: &pvd, at: 156)
        put(pvd, into: &image, at: 16 * block)
        put([255] + ascii("CD001") + [1], into: &image, at: 17 * block)
        put(directory, into: &image, at: 18 * block)
        return Data(image + payload)
    }

    /// A classic HFS volume named `name` with, at its root, an application
    /// (data fork `data`, resource fork `resource`) and the volume's custom
    /// icon file `Icon\r` (resource fork `volumeIcon`).
    static func hfs(name: String, application: String, data: [UInt8], resource: [UInt8], volumeIcon: [UInt8]) -> Data {
        let blockSize = 512
        let firstSector = 4  // allocation block 0 at 2048
        func blocks(_ count: Int) -> Int { (count + blockSize - 1) / blockSize }
        // Allocation blocks: 0 extents file, 1–2 catalog, then the forks.
        let dataStart = 3
        let resourceStart = dataStart + max(1, blocks(data.count))
        let iconStart = resourceStart + max(1, blocks(resource.count))
        let total = iconStart + max(1, blocks(volumeIcon.count))
        var volume = [UInt8](repeating: 0, count: firstSector * 512 + total * blockSize)

        var mdb = [UInt8](repeating: 0, count: 512)
        put(ascii("BD"), into: &mdb, at: 0)
        put(be16(total), into: &mdb, at: 18)
        put(be32(blockSize), into: &mdb, at: 20)
        put(be16(firstSector), into: &mdb, at: 28)
        put(pascal(name), into: &mdb, at: 36)
        put(be32(512), into: &mdb, at: 130)
        put(be16(0) + be16(1), into: &mdb, at: 134)
        put(be32(1024), into: &mdb, at: 146)
        put(be16(1) + be16(2), into: &mdb, at: 150)
        put(mdb, into: &volume, at: 1024)

        func header(firstLeaf: Int) -> [UInt8] {
            var node = [UInt8](repeating: 0, count: 512)
            node[8] = 1
            put(be16(3), into: &node, at: 10)
            put(be16(1) + be32(firstLeaf) + be32(3) + be32(firstLeaf) + be32(firstLeaf) + be16(512) + be16(37)
                + be32(2) + be32(0), into: &node, at: 14)
            return node
        }
        put(header(firstLeaf: 0), into: &volume, at: firstSector * 512)
        put(header(firstLeaf: 1), into: &volume, at: firstSector * 512 + blockSize)

        func key(parent: Int, name: String) -> [UInt8] {
            let body = [0] + be32(parent) + pascal(name)
            var key = [UInt8(body.count)] + body
            if key.count % 2 == 1 { key.append(0) }
            return key
        }
        func file(id: Int, type: String, creator: String, flags: Int, dataStart: Int, dataLength: Int,
                  resourceStart: Int, resourceLength: Int) -> [UInt8] {
            var record = [UInt8](repeating: 0, count: 102)
            record[0] = 2
            put(ascii(type) + ascii(creator) + be16(flags), into: &record, at: 4)
            put(be32(id), into: &record, at: 20)
            put(be32(dataLength), into: &record, at: 26)
            put(be32(resourceLength), into: &record, at: 36)
            put(be16(dataStart) + be16(max(1, blocks(dataLength))), into: &record, at: 74)
            put(be16(resourceStart) + be16(max(1, blocks(resourceLength))), into: &record, at: 86)
            return record
        }
        var root = [UInt8](repeating: 0, count: 70)
        root[0] = 1
        put(be32(2), into: &root, at: 6)
        let records = [
            key(parent: 1, name: name) + root,
            key(parent: 2, name: application) + file(id: 16, type: "APPL", creator: "TEST", flags: 0, dataStart: dataStart,
                                                     dataLength: data.count, resourceStart: resourceStart,
                                                     resourceLength: resource.count),
            key(parent: 2, name: "Icon\r") + file(id: 17, type: "icon", creator: "MACS", flags: 0x4000, dataStart: 0,
                                                  dataLength: 0, resourceStart: iconStart, resourceLength: volumeIcon.count),
        ]
        var leaf = [UInt8](repeating: 0, count: 512)
        leaf[8] = 0xFF
        leaf[9] = 1
        put(be16(records.count), into: &leaf, at: 10)
        var offset = 14
        for (index, record) in records.enumerated() {
            put(record, into: &leaf, at: offset)
            put(be16(offset), into: &leaf, at: 512 - 2 * (index + 1))
            offset += record.count
        }
        put(be16(offset), into: &leaf, at: 512 - 2 * (records.count + 1))
        put(leaf, into: &volume, at: firstSector * 512 + 2 * blockSize)
        put(data, into: &volume, at: firstSector * 512 + dataStart * blockSize)
        put(resource, into: &volume, at: firstSector * 512 + resourceStart * blockSize)
        put(volumeIcon, into: &volume, at: firstSector * 512 + iconStart * blockSize)
        return Data(volume)
    }

    // MARK: - Damage

    /// `data` cut short at several lengths, and with bytes flipped through
    /// it: what a parser must survive.
    static func damaged(_ data: Data) -> [Data] {
        var variants: [Data] = []
        for fraction in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99] {
            variants.append(data.prefix(Int(Double(data.count) * fraction)))
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            var bytes = [UInt8](data)
            guard !bytes.isEmpty else { break }
            for _ in 0..<8 {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = [0x00, 0xFF, 0x7F, 0x80].randomElement(using: &generator) ?? 0xFF
            }
            variants.append(Data(bytes))
        }
        return variants
    }
}
