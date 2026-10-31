//
//  VDF.swift
//  Shared
//
//  Valve's KeyValues format, which Steam keeps its state in: the text form
//  (appmanifest_*.acf, loginusers.vdf) and the binary form of its app and
//  package caches (appcache/appinfo.vdf, appcache/packageinfo.vdf).

import Foundation

/// One KeyValues value. Keys keep their order and their case; Steam treats
/// them as case-insensitive, so lookups do too.
nonisolated indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case float(Double)
    case object([VDFEntry])

    /// The first entry under `key`, ignoring case.
    subscript(key: String) -> VDFValue? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    var entries: [VDFEntry] {
        if case .object(let entries) = self { return entries }
        return []
    }

    /// A string as Steam writes it, also for numbers: text VDF has only strings.
    var string: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .float(let value): return String(value)
        case .object: return nil
        }
    }

    var int: Int64? {
        switch self {
        case .int(let value): return value
        case .string(let value): return Int64(value)
        default: return nil
        }
    }
}

nonisolated struct VDFEntry: Equatable, Sendable {
    let key: String
    let value: VDFValue
}

nonisolated enum VDFError: Error, Equatable {
    case unexpectedEnd
    case unexpected(String, line: Int)
    case badBinary(String, offset: Int)
}

nonisolated enum VDF {
    // MARK: Text

    /// Parse text KeyValues into an object of its top-level entries.
    /// `[$WIN32]`-style conditions are dropped, as Steam does on a Mac-less read.
    static func parse(_ text: String) throws -> VDFValue {
        var tokens = Tokenizer(text)
        let entries = try parseEntries(&tokens, closedByBrace: false)
        return .object(entries)
    }

    private static func parseEntries(_ tokens: inout Tokenizer, closedByBrace: Bool) throws -> [VDFEntry] {
        var entries: [VDFEntry] = []
        while let token = try tokens.next() {
            switch token {
            case .close:
                guard closedByBrace else { throw VDFError.unexpected("}", line: tokens.line) }
                return entries
            case .open:
                throw VDFError.unexpected("{", line: tokens.line)
            case .word(let key):
                guard let next = try tokens.next() else { throw VDFError.unexpectedEnd }
                switch next {
                case .word(let value):
                    entries.append(VDFEntry(key: key, value: .string(value)))
                case .open:
                    entries.append(VDFEntry(key: key, value: .object(try parseEntries(&tokens, closedByBrace: true))))
                case .close:
                    throw VDFError.unexpected("}", line: tokens.line)
                }
            }
        }
        if closedByBrace { throw VDFError.unexpectedEnd }
        return entries
    }

    private enum Token: Equatable {
        case word(String)
        case open
        case close
    }

    private struct Tokenizer {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        private(set) var line = 1

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        mutating func next() throws -> Token? {
            while index < scalars.count {
                let c = scalars[index]
                if c == "\n" { line += 1; index += 1; continue }
                if c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { index += 1; continue }
                if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                if c == "[" {  // a platform condition such as [$WIN32]
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1
                    continue
                }
                if c == "{" { index += 1; return .open }
                if c == "}" { index += 1; return .close }
                if c == "\"" { return .word(try quoted()) }
                return .word(bare())
            }
            return nil
        }

        private mutating func quoted() throws -> String {
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" { return String(out) }
                if c == "\n" { line += 1 }
                if c == "\\", index < scalars.count {
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(escaped)  // \\ and \"
                    }
                    continue
                }
                out.append(c)
            }
            throw VDFError.unexpectedEnd
        }

        private mutating func bare() -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c == " " || c == "\t" || c == "\r" || c == "\n" || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                index += 1
            }
            return String(out)
        }
    }

    /// Text KeyValues for `entries`, tab-indented the way Steam writes them.
    static func format(_ entries: [VDFEntry], indent: Int = 0) -> String {
        let pad = String(repeating: "\t", count: indent)
        var out = ""
        for entry in entries {
            switch entry.value {
            case .object(let children):
                out += "\(pad)\(quote(entry.key))\n\(pad){\n"
                out += format(children, indent: indent + 1)
                out += "\(pad)}\n"
            default:
                out += "\(pad)\(quote(entry.key))\t\t\(quote(entry.value.string ?? ""))\n"
            }
        }
        return out
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Binary

    /// Binary KeyValues from `offset` up to its end marker. With `strings`,
    /// keys are indices into that table (appinfo.vdf v29); otherwise they are
    /// inline, NUL-terminated.
    static func parseBinary(_ data: Data, at offset: inout Int, strings: [String]? = nil) throws -> [VDFEntry] {
        var reader = BinaryReader(data: data, offset: offset)
        let entries = try reader.readEntries(strings: strings)
        offset = reader.offset
        return entries
    }
}

/// Little-endian reads over `Data`, bounds-checked.
nonisolated struct BinaryReader {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    private func check(_ count: Int) throws {
        guard offset >= 0, offset + count <= data.count else {
            throw VDFError.badBinary("read of \(count) bytes past the end", offset: offset)
        }
    }

    mutating func uint8() throws -> UInt8 {
        try check(1)
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func uint32() throws -> UInt32 {
        try check(4)
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[data.startIndex + offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return value
    }

    mutating func uint64() throws -> UInt64 {
        try check(8)
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[data.startIndex + offset + i]) << (8 * UInt64(i)) }
        offset += 8
        return value
    }

    mutating func skip(_ count: Int) throws {
        try check(count)
        offset += count
    }

    /// A NUL-terminated UTF-8 string.
    mutating func cString() throws -> String {
        let start = data.startIndex + offset
        guard let end = data[start...].firstIndex(of: 0) else {
            throw VDFError.badBinary("unterminated string", offset: offset)
        }
        offset += end - start + 1
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    mutating func readEntries(strings: [String]?) throws -> [VDFEntry] {
        var entries: [VDFEntry] = []
        while true {
            let type = try uint8()
            if type == 0x08 { return entries }  // end of this object
            let key: String
            if let strings {
                let index = Int(try uint32())
                guard index < strings.count else {
                    throw VDFError.badBinary("key index \(index) outside a table of \(strings.count)", offset: offset)
                }
                key = strings[index]
            } else {
                key = try cString()
            }
            let value: VDFValue
            switch type {
            case 0x00: value = .object(try readEntries(strings: strings))
            case 0x01: value = .string(try cString())
            case 0x02, 0x04, 0x06: value = .int(Int64(Int32(bitPattern: try uint32())))  // int32, pointer, colour
            case 0x03: value = .float(Double(Float(bitPattern: try uint32())))
            case 0x07: value = .int(Int64(bitPattern: try uint64()))  // uint64
            case 0x0A: value = .int(Int64(bitPattern: try uint64()))  // int64
            default: throw VDFError.badBinary("unknown value type \(type)", offset: offset - 1)
            }
            entries.append(VDFEntry(key: key, value: value))
        }
    }
}
