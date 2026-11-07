//
//  ShellLink.swift
//  WindowsFormats
//
//  A Windows shortcut (.lnk): the program it opens and the icon it shows.
//  An installer's Start menu and desktop shortcuts name the program it
//  installed, and its icon, more surely than any guess. The layout is
//  Microsoft's [MS-SHLLINK]: a 76-byte header, an optional item ID list, an
//  optional LinkInfo (the target's local path), then counted strings for
//  the name, relative path, working directory, arguments and icon location,
//  then extra data blocks. The item ID list isn't read: LinkInfo, the
//  relative path or the environment block name the target well enough.

import Foundation

nonisolated public struct ShellLink: Sendable, Equatable {
    /// The target, as a Windows path (`C:\Games\Game.exe`), when the link
    /// says it in a way read here.
    public let target: String?
    public let relativePath: String?
    public let workingDirectory: String?
    public let arguments: String?
    public let name: String?
    /// The file the icon comes from, when the link has its own; otherwise
    /// the target's icon is shown.
    public let iconLocation: String?
    /// Which icon in `iconLocation` (or the target): see `ProgramIcons.group(forIconIndex:)`.
    public let iconIndex: Int

    /// Nil if `data` isn't a shell link.
    public init?(data: Data) {
        let clsid: [UInt8] = [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x46]
        guard data.u32(at: 0) == 0x4C, let guid = data.bytes(in: 4..<20), guid.elementsEqual(clsid),
              let flags = data.u32(at: 0x14), let rawIconIndex = data.u32(at: 0x38) else { return nil }
        iconIndex = Int(Int32(truncatingIfNeeded: rawIconIndex))
        let unicode = flags & 0x80 != 0
        var offset = 0x4C
        if flags & 0x01 != 0 {  // HasLinkTargetIDList
            guard let size = data.u16(at: offset) else { return nil }
            offset += 2 + size
        }
        var target: String?
        if flags & 0x02 != 0 {  // HasLinkInfo
            guard let size = data.u32(at: offset), size >= 0x1C else { return nil }
            target = Self.linkInfoPath(data, at: offset)
            offset += size
        }
        func nextString(_ present: Bool) -> String? {
            guard present, let count = data.u16(at: offset) else { return nil }
            offset += 2
            let byteCount = unicode ? count * 2 : count
            defer { offset += byteCount }
            guard let bytes = data.bytes(in: offset..<(offset + byteCount)) else { return nil }
            return unicode ? String(decoding: (0..<count).compactMap { bytes.u16(at: $0 * 2) }.map(UInt16.init),
                                    as: UTF16.self)
                : String(data: bytes, encoding: .windowsCP1252)
        }
        name = nextString(flags & 0x04 != 0)
        relativePath = nextString(flags & 0x08 != 0)
        workingDirectory = nextString(flags & 0x10 != 0)
        arguments = nextString(flags & 0x20 != 0)
        var icon = nextString(flags & 0x40 != 0)

        // Extra data blocks: the environment-variable target and icon, used
        // when the strings have %variables%.
        var blocks = 0
        while blocks < 64, let size = data.u32(at: offset), size >= 8, let signature = data.u32(at: offset + 4) {
            if signature == 0xA000_0001, target == nil {
                target = Self.blockPath(data, at: offset)
            } else if signature == 0xA000_0007, icon == nil || icon?.isEmpty == true {
                icon = Self.blockPath(data, at: offset)
            }
            offset += size
            blocks += 1
        }
        self.target = target ?? relativePath
        iconLocation = icon.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// LinkInfo's local base path, with its common suffix.
    private static func linkInfoPath(_ data: Data, at start: Int) -> String? {
        guard let flags = data.u32(at: start + 8), flags & 1 != 0, let headerSize = data.u32(at: start + 4),
              let baseOffset = data.u32(at: start + 16), let suffixOffset = data.u32(at: start + 24) else { return nil }
        if headerSize >= 0x24, let unicodeBase = data.u32(at: start + 28), unicodeBase != 0 {
            let suffix = data.u32(at: start + 32).map { utf16CString(data, at: start + $0) } ?? ""
            return utf16CString(data, at: start + unicodeBase) + suffix
        }
        return ansiCString(data, at: start + baseOffset) + ansiCString(data, at: start + suffixOffset)
    }

    /// An environment data block's path: its Unicode copy if it has one.
    private static func blockPath(_ data: Data, at start: Int) -> String? {
        let unicode = utf16CString(data, at: start + 8 + 260)
        let path = unicode.isEmpty ? ansiCString(data, at: start + 8) : unicode
        return path.isEmpty ? nil : path
    }

    private static func ansiCString(_ data: Data, at offset: Int) -> String {
        var bytes: [UInt8] = []
        while bytes.count < 1024, let byte = data.u8(at: offset + bytes.count), byte != 0 { bytes.append(UInt8(byte)) }
        return String(data: Data(bytes), encoding: .windowsCP1252) ?? ""
    }

    private static func utf16CString(_ data: Data, at offset: Int) -> String {
        var units: [UInt16] = []
        while units.count < 1024, let unit = data.u16(at: offset + units.count * 2), unit != 0 {
            units.append(UInt16(unit))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// A disc's autorun.inf: what Windows opened when it went in, and the icon
/// it showed for the drive (often the box's logo).
nonisolated public struct AutorunInf: Sendable, Equatable {
    /// The program it opens, without arguments (`setup.exe`).
    public let open: String?
    /// The icon file, a path on the disc, and which icon in it.
    public let icon: String?
    public let iconIndex: Int
    /// The drive's label in Explorer.
    public let label: String?

    public init?(text: String) {
        var section = ""
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(1000) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
                continue
            }
            guard section == "autorun", !line.hasPrefix(";"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }
        }
        guard !values.isEmpty else { return nil }
        open = values["open"].map { Self.programPath($0) }
        if let icon = values["icon"] {
            let parts = icon.split(separator: ",", maxSplits: 1)
            self.icon = parts.first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            iconIndex = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        } else {
            icon = nil
            iconIndex = 0
        }
        label = values["label"]
    }

    /// The program part of an `open=` line: quoted, or up to the first space.
    private static func programPath(_ value: String) -> String {
        if value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        return value.split(separator: " ").first.map(String.init) ?? value
    }
}
