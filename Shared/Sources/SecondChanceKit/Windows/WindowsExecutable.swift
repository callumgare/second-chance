//
//  WindowsExecutable.swift
//  Shared
//
//  Just enough of the PE format to read what Second Chance needs from a
//  Windows program: the DLLs it imports, which say what a game draws with
//  (GameGraphicsAPI), and the strings in its version info, which say which
//  game an installer is for and which kind of installer it is (GameDetector,
//  GameInstallerRunner). Every read is bounds-checked and every loop capped,
//  so a damaged or truncated file gives less back, never a crash.
//  The layouts are Microsoft's "PE Format" and "VS_VERSIONINFO" documentation.

import Foundation

nonisolated public struct WindowsExecutable: Sendable {
    private let bytes: Data
    private let sections: [Section]
    /// Where the optional header's data directories start, and how many there are.
    private let directories: Int
    private let directoryCount: Int

    private struct Section: Sendable {
        let name: String
        let virtualAddress: Int
        let size: Int
        let rawOffset: Int
    }

    /// Mapped rather than read in, since an installer can be hundreds of MB.
    /// Nil if the file can't be read or isn't a PE image.
    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// Nil if `data` isn't a PE image.
    public init?(data: Data) {
        let bytes = data
        guard bytes.u16(at: 0) == 0x5A4D,  // "MZ"
              let pe = bytes.u32(at: 0x3C), bytes.u32(at: pe) == 0x0000_4550,  // "PE\0\0"
              let sectionCount = bytes.u16(at: pe + 6),
              let optionalSize = bytes.u16(at: pe + 20) else { return nil }
        let optional = pe + 24
        // The data directories start later in PE32+ than in PE32.
        switch bytes.u16(at: optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }
        directoryCount = bytes.u32(at: directories - 4) ?? 0

        // Sections map RVAs to file offsets.
        let sectionTable = optional + optionalSize
        var sections: [Section] = []
        for index in 0..<sectionCount {
            let header = sectionTable + index * 40
            guard let virtualSize = bytes.u32(at: header + 8), let virtualAddress = bytes.u32(at: header + 12),
                  let rawSize = bytes.u32(at: header + 16), let rawOffset = bytes.u32(at: header + 20) else { break }
            // Eight bytes, padded with NULs.
            let nameBytes = (0..<8).compactMap { bytes.u8(at: header + $0) }.prefix { $0 != 0 }
            let name = String(decoding: nameBytes.map(UInt8.init), as: UTF8.self)
            sections.append(Section(name: name, virtualAddress: virtualAddress, size: max(virtualSize, rawSize),
                                    rawOffset: rawOffset))
        }
        self.bytes = bytes
        self.sections = sections
    }

    // MARK: - Sections

    /// The names of the program's sections, as its section table has them
    /// (".text", ".rdata" …). Packers and copy protection add their own.
    public var sectionNames: [String] { sections.map(\.name) }

    // MARK: - Imports

    /// The lower-cased names of the DLLs the program imports: its import
    /// directory, not delay-loaded DLLs. Empty if it has none, or they can't
    /// be read.
    public var importedDLLs: Set<String> {
        guard let imports = directory(1), var descriptor = fileOffset(ofRVA: imports) else { return [] }
        var names: Set<String> = []
        // Import descriptors, 20 bytes each, ending with an all-zero one. Capped
        // in case a damaged file never ends the list.
        for _ in 0..<1024 {
            guard let lookup = bytes.u32(at: descriptor), let nameRVA = bytes.u32(at: descriptor + 12),
                  let addresses = bytes.u32(at: descriptor + 16) else { break }
            if lookup == 0 && nameRVA == 0 && addresses == 0 { break }
            if let name = cString(atRVA: nameRVA) { names.insert(name.lowercased()) }
            descriptor += 20
        }
        return names
    }

    // MARK: - Version info

    /// The strings in the program's version info — "ProductName",
    /// "CompanyName", "Comments" and the like — from its US English table if it
    /// has one, otherwise its first. A string that is empty is left out, so a
    /// missing one is never mistaken for another. Empty if it has no version
    /// info, or it can't be read.
    public var versionStrings: [String: String] {
        guard let resource = versionResource(),
              let root = versionNode(at: resource.lowerBound, within: resource.upperBound, base: resource.lowerBound),
              root.key == "VS_VERSION_INFO" else { return [:] }
        let base = resource.lowerBound
        // StringFileInfo and VarFileInfo may come in either order.
        guard let stringFileInfo = children(of: root, base: base).first(where: { $0.key == "StringFileInfo" })
        else { return [:] }
        let tables = children(of: stringFileInfo, base: base)
        guard let table = tables.first(where: { $0.key.lowercased().hasPrefix("0409") }) ?? tables.first
        else { return [:] }

        var strings: [String: String] = [:]
        for string in children(of: table, base: base) {
            // A text value's length is meant to count UTF-16 units, but some
            // programs count bytes, so it's read to its NUL instead, within
            // the string's own bounds.
            let value = utf16String(from: string.value.lowerBound, before: string.end)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, strings[string.key] == nil {
                strings[string.key] = value
            }
        }
        return strings
    }

    /// Where the version resource's data is: the first name and the first
    /// language under RT_VERSION (16) in the resource directory.
    private func versionResource() -> Range<Int>? {
        guard let resources = directory(2), let root = fileOffset(ofRVA: resources),
              let type = resourceEntries(at: root, root: root).first(where: { $0.id == 16 && $0.isDirectory }),
              let name = resourceEntries(at: root + type.offset, root: root).first(where: \.isDirectory),
              let language = resourceEntries(at: root + name.offset, root: root).first(where: { !$0.isDirectory }),
              let dataRVA = bytes.u32(at: root + language.offset),
              let size = bytes.u32(at: root + language.offset + 4),
              let start = fileOffset(ofRVA: dataRVA), start < bytes.count else { return nil }
        return start..<min(start + size, bytes.count)
    }

    private struct ResourceEntry {
        /// Nil for an entry with a name rather than a number.
        let id: Int?
        /// From the start of the resource section.
        let offset: Int
        let isDirectory: Bool
    }

    /// The entries of the resource directory at `offset`: named ones first,
    /// then numbered ones.
    private func resourceEntries(at offset: Int, root: Int) -> [ResourceEntry] {
        guard let named = bytes.u16(at: offset + 12), let numbered = bytes.u16(at: offset + 14) else { return [] }
        var entries: [ResourceEntry] = []
        for index in 0..<min(named + numbered, 4096) {
            let entry = offset + 16 + index * 8
            guard let name = bytes.u32(at: entry), let target = bytes.u32(at: entry + 4) else { break }
            entries.append(ResourceEntry(
                id: name & 0x8000_0000 == 0 ? name : nil,
                offset: target & 0x7FFF_FFFF,
                isDirectory: target & 0x8000_0000 != 0))
        }
        return entries
    }

    /// One node of a VS_VERSIONINFO tree: VS_VERSION_INFO itself,
    /// StringFileInfo, a StringTable, a String, VarFileInfo or a Var. Each is
    /// its length, its value's length, its type (1 for text), a NUL-ended
    /// UTF-16 key, padding to 32 bits, its value, more padding, and its children.
    private struct VersionNode {
        let key: String
        let value: Range<Int>
        let children: Range<Int>
        let end: Int
    }

    /// Padding is to 32 bits from the start of the version resource.
    private func aligned(_ offset: Int, base: Int) -> Int {
        base + ((offset - base + 3) & ~3)
    }

    private func versionNode(at offset: Int, within limit: Int, base: Int) -> VersionNode? {
        guard let length = bytes.u16(at: offset), let valueLength = bytes.u16(at: offset + 2),
              let type = bytes.u16(at: offset + 4), length >= 6, offset + length <= limit else { return nil }
        let end = offset + length
        let key = utf16String(from: offset + 6, before: end)
        let keyEnd = offset + 6 + (key.utf16.count + 1) * 2
        let valueStart = min(aligned(keyEnd, base: base), end)
        let valueEnd = min(valueStart + (type == 1 ? valueLength * 2 : valueLength), end)
        let childrenStart = min(aligned(valueEnd, base: base), end)
        return VersionNode(key: key, value: valueStart..<valueEnd, children: childrenStart..<end, end: end)
    }

    private func children(of node: VersionNode, base: Int) -> [VersionNode] {
        var children: [VersionNode] = []
        var offset = node.children.lowerBound
        while offset < node.children.upperBound, children.count < 1024,
              let child = versionNode(at: offset, within: node.children.upperBound, base: base) {
            children.append(child)
            offset = aligned(child.end, base: base)
        }
        return children
    }

    // MARK: - Reading

    /// The RVA of data directory `index`, if the program has one there.
    private func directory(_ index: Int) -> Int? {
        guard index < directoryCount, let rva = bytes.u32(at: directories + index * 8), rva != 0 else { return nil }
        return rva
    }

    private func fileOffset(ofRVA rva: Int) -> Int? {
        sections.first { rva >= $0.virtualAddress && rva < $0.virtualAddress + $0.size }
            .map { $0.rawOffset + (rva - $0.virtualAddress) }
    }

    private func cString(atRVA rva: Int) -> String? {
        guard var offset = fileOffset(ofRVA: rva) else { return nil }
        var characters: [UInt8] = []
        while let byte = bytes.u8(at: offset), byte != 0, characters.count < 256 {
            characters.append(UInt8(byte))
            offset += 1
        }
        return String(bytes: characters, encoding: .ascii)
    }

    /// UTF-16LE from `offset` to its NUL, or to `end`.
    private func utf16String(from offset: Int, before end: Int) -> String {
        var units: [UInt16] = []
        var position = offset
        while position + 2 <= end, units.count < 4096, let unit = bytes.u16(at: position), unit != 0 {
            units.append(UInt16(unit))
            position += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
