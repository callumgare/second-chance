//
//  NEExecutable.swift
//  WindowsFormats
//
//  A 16-bit Windows program (NE, "New Executable": Windows 3.x and its
//  icon libraries), read for its resources. Its resource table sits at the
//  NE header + its offset at 0x24: a shift count for the alignment, then a
//  list of types, each with its resources' offsets and lengths in units of
//  that alignment. Icons, cursors and bitmaps are the same DIBs a PE holds,
//  with the high bit set on their type numbers (0x8003 is RT_ICON). The
//  layout is Microsoft's "Executable-File Header Format" (Windows 3.1 SDK).
//  Every read is bounds-checked and every loop capped.

import Foundation

nonisolated public struct NEExecutable: Sendable {
    private let bytes: Data
    private let header: Int

    /// Nil if `data` isn't an NE program.
    public init?(data: Data) {
        guard data.u16(at: 0) == 0x5A4D, let header = data.u32(at: 0x3C), header >= 0x40,
              data.u16(at: header) == 0x454E else { return nil }  // "NE"
        bytes = data
        self.header = header
    }

    /// The operating system it's for: 1 OS/2, 2 Windows, 4 Windows 386.
    public var targetOS: Int? { bytes.u8(at: header + 0x36) }

    /// The module's name: the first entry of its resident-name table.
    public var moduleName: String? {
        guard let offset = bytes.u16(at: header + 0x26), let length = bytes.u8(at: header + offset), length > 0,
              let name = bytes.bytes(in: (header + offset + 1)..<(header + offset + 1 + length)) else { return nil }
        return String(data: name, encoding: .windowsCP1252)
    }

    /// Every resource, in table order, its type and name as PE has them
    /// (the high bit that marks a number dropped).
    public var resources: [WindowsResource] {
        guard let tableOffset = bytes.u16(at: header + 0x24), let namesOffset = bytes.u16(at: header + 0x26),
              namesOffset > tableOffset else { return [] }
        let table = header + tableOffset
        guard let shift = bytes.u16(at: table), shift < 16 else { return [] }
        var resources: [WindowsResource] = []
        var offset = table + 2
        for _ in 0..<1024 {
            guard let typeID = bytes.u16(at: offset), typeID != 0, let count = bytes.u16(at: offset + 2) else { break }
            let type = name(typeID, table: table)
            offset += 8
            for _ in 0..<min(count, 4096) {
                guard let start = bytes.u16(at: offset), let length = bytes.u16(at: offset + 2),
                      let id = bytes.u16(at: offset + 6) else { return resources }
                offset += 12
                // Lengths are rounded up to the alignment, which can run past
                // the end of a file whose last resource isn't padded.
                let from = start << shift
                let end = min(from + (length << shift), max(from, bytes.count))
                resources.append(WindowsResource(type: type, name: name(id, table: table), language: 0,
                                                 data: bytes.bytes(in: from..<end)))
            }
        }
        return resources
    }

    /// A type or name: a number if its high bit is set, otherwise the offset
    /// of a length-prefixed string from the table's start.
    private func name(_ value: Int, table: Int) -> ResourceName {
        if value & 0x8000 != 0 { return .id(value & 0x7FFF) }
        guard let length = bytes.u8(at: table + value),
              let text = bytes.bytes(in: (table + value + 1)..<(table + value + 1 + length)) else { return .id(value) }
        return .name(String(data: text, encoding: .windowsCP1252) ?? "?")
    }
}
