//
//  MSIStreams.swift
//  WindowsFormats
//
//  The streams of an MSI, by their real names. An MSI's tables and binary
//  values are streams of its compound file, their names packed two
//  characters to a UTF-16 unit (Windows Installer's "stream name
//  compression"). A binary column's value is a stream of its own, named
//  `<table>.<key>`: `Icon.ProductIcon.exe` is the Icon table's row
//  `ProductIcon.exe`, the icon the installer's shortcuts show (an .ico, or a
//  program holding one), and `Binary.<name>` the installer's dialog
//  bitmaps. Embedded cabinets are streams too, starting with "MSCF".

import Foundation

nonisolated public struct MSIStreams: Sendable {
    public struct Stream: Sendable {
        /// The decoded name: `Icon.ProductIcon.exe`, `Binary.bannrbmp`, a
        /// cabinet's name. A table's stream is `!` and the table's name.
        public let name: String
        public let data: Data
    }

    public let streams: [Stream]

    /// Nil if `data` isn't a compound file. Mapped data is fine: streams are
    /// copied out as they are read.
    public init?(data: Data) {
        guard let file = CompoundFile(data) else { return nil }
        streams = file.allStreams().map { Stream(name: Self.decode($0.name), data: $0.data) }
    }

    /// The Icon table's icons: each row's key, and its file.
    public var icons: [Stream] { streams.filter { $0.name.hasPrefix("Icon.") } }
    /// The Binary table's values: dialog bitmaps, custom action DLLs.
    public var binaries: [Stream] { streams.filter { $0.name.hasPrefix("Binary.") } }
    /// Cabinets embedded in the MSI.
    public var cabinets: [Stream] { streams.filter { $0.data.prefix(4) == Data("MSCF".utf8) } }

    /// A stream name as Windows Installer wrote it, unpacked: each unit in
    /// 0x3800–0x47FF holds two characters of a 64-character alphabet,
    /// 0x4800–0x483F one, and 0x4840 marks a table.
    public static func decode(_ name: String) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._")
        var decoded = ""
        for unit in name.utf16 {
            switch unit {
            case 0x3800..<0x4800:
                let value = Int(unit - 0x3800)
                decoded.append(alphabet[value & 0x3F])
                decoded.append(alphabet[(value >> 6) & 0x3F])
            case 0x4800..<0x4840:
                decoded.append(alphabet[Int(unit - 0x4800)])
            case 0x4840:
                decoded.append("!")
            default:
                decoded += String(decoding: [unit], as: UTF16.self)
            }
        }
        return decoded
    }
}
