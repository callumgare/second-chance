//
//  MacFile.swift
//  ClassicMacFormats
//
//  A classic Mac file carried somewhere that keeps only one fork: MacBinary
//  (a 128-byte header, then both forks), AppleSingle and AppleDouble (an
//  entry table; AppleDouble's `._name` holds all but the data fork), and
//  BinHex 4.0 (text, run-length and 6-bit encoded). Each gives back the file
//  as the Finder knew it: its name, type, creator, Finder flags and forks.
//  Every read is bounds-checked; a damaged file gives nil.

import Foundation

nonisolated public struct MacFile: Sendable {
    public var name: String
    /// The Finder's file type and creator ('APPL', 'PICT'; the app's code).
    public var type: String
    public var creator: String
    /// kHasCustomIcon is 0x0400, kIsInvisible 0x4000.
    public var finderFlags: Int
    public var dataFork: Data
    public var resourceFork: Data?

    public init(name: String, type: String, creator: String, finderFlags: Int, dataFork: Data, resourceFork: Data?) {
        self.name = name
        self.type = type
        self.creator = creator
        self.finderFlags = finderFlags
        self.dataFork = dataFork
        self.resourceFork = resourceFork
    }

    public var hasCustomIcon: Bool { finderFlags & 0x0400 != 0 }
}

// MARK: - MacBinary

nonisolated public enum MacBinary {
    /// Nil if `data` isn't MacBinary (I, II or III). The header has no magic
    /// before III, so this checks every field that must be zero and that the
    /// forks' lengths fit the file.
    public static func decode(_ data: Data) -> MacFile? {
        guard data.count >= 128, data.be8(at: 0) == 0, data.be8(at: 74) == 0, data.be8(at: 82) == 0,
              let nameLength = data.be8(at: 1), (1...63).contains(nameLength),
              let name = data.pascalString(at: 1, maxLength: 63),
              let type = data.osType(at: 65), let creator = data.osType(at: 69),
              let flagsHigh = data.be8(at: 73), let flagsLow = data.be8(at: 101),
              let dataLength = data.be32(at: 83), let resourceLength = data.be32(at: 87),
              let secondaryHeader = data.be16(at: 120),
              dataLength < 0x7FFF_FFFF, resourceLength < 0x7FFF_FFFF else { return nil }
        let headerEnd = 128 + ((secondaryHeader + 127) & ~127)
        let resourceStart = headerEnd + ((dataLength + 127) & ~127)
        // The forks must fit, and not leave much behind them (a Get Info comment at most).
        guard resourceStart + resourceLength <= data.count,
              data.count - (resourceStart + resourceLength) < 128 + 4096,
              dataLength + resourceLength > 0,
              let dataFork = data.subdata(checked: headerEnd..<(headerEnd + dataLength)),
              let resourceFork = data.subdata(checked: resourceStart..<(resourceStart + resourceLength)) else { return nil }
        return MacFile(name: name, type: type, creator: creator, finderFlags: flagsHigh << 8 | flagsLow,
                       dataFork: dataFork, resourceFork: resourceFork.isEmpty ? nil : resourceFork)
    }
}

// MARK: - AppleSingle and AppleDouble

nonisolated public enum AppleSingle {
    public static let singleMagic = 0x0005_1600
    public static let doubleMagic = 0x0005_1607

    /// Nil if `data` isn't AppleSingle or AppleDouble. An AppleDouble file
    /// has no data fork (it's the file beside it): `dataFork` is empty, to
    /// be filled from that file.
    public static func decode(_ data: Data, name fallbackName: String = "") -> MacFile? {
        guard let magic = data.be32(at: 0), magic == singleMagic || magic == doubleMagic,
              let count = data.be16(at: 24), count <= 64 else { return nil }
        var file = MacFile(name: fallbackName, type: "", creator: "", finderFlags: 0, dataFork: Data(), resourceFork: nil)
        for index in 0..<count {
            let entry = 26 + index * 12
            guard let id = data.be32(at: entry), let offset = data.be32(at: entry + 4),
                  let length = data.be32(at: entry + 8),
                  let bytes = data.subdata(checked: offset..<(offset + length)) else { continue }
            switch id {
            case 1: file.dataFork = bytes
            case 2: file.resourceFork = bytes.isEmpty ? nil : bytes
            case 3: file.name = MacRoman.string(bytes)
            case 9:
                file.type = bytes.osType(at: 0) ?? ""
                file.creator = bytes.osType(at: 4) ?? ""
                file.finderFlags = bytes.be16(at: 8) ?? 0
            default: break
            }
        }
        return file
    }
}

// MARK: - BinHex 4.0

nonisolated public enum BinHex {
    private static let alphabet = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)

    /// Whether `head` (the start of a file) looks like BinHex.
    public static func looksLike(_ head: Data) -> Bool {
        head.range(of: Data("(This file must be converted with BinHex".utf8)) != nil
    }

    /// Nil if `data` isn't BinHex 4.0, or is damaged. CRCs aren't checked:
    /// a file with a bad one still gives what it can.
    public static func decode(_ data: Data) -> MacFile? {
        guard let marker = data.range(of: Data("(This file must be converted with BinHex".utf8)),
              let colon = data[marker.upperBound...].firstIndex(of: UInt8(ascii: ":")) else { return nil }
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, character) in alphabet.enumerated() { table[Int(character)] = UInt8(index) }

        // 6-bit characters to bytes, to the closing colon.
        var packed: [UInt8] = []
        packed.reserveCapacity(data.count * 3 / 4)
        var accumulator = 0
        var bits = 0
        for byte in data[(colon + 1)...] {
            if byte == UInt8(ascii: ":") { break }
            let value = table[Int(byte)]
            guard value != 0xFF else {
                if byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09 { continue }
                return nil
            }
            accumulator = accumulator << 6 | Int(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                packed.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }

        // Runs: 0x90 n repeats the byte before n-1 more times; 0x90 0 is 0x90.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(packed.count)
        var index = 0
        while index < packed.count {
            let byte = packed[index]
            if byte == 0x90, index + 1 < packed.count {
                let count = Int(packed[index + 1])
                if count == 0 {
                    bytes.append(0x90)
                } else if let last = bytes.last {
                    bytes += [UInt8](repeating: last, count: count - 1)
                }
                index += 2
                guard bytes.count < 1 << 30 else { return nil }
            } else {
                bytes.append(byte)
                index += 1
            }
        }

        let decoded = Data(bytes)
        guard let nameLength = decoded.be8(at: 0), let name = decoded.pascalString(at: 0) else { return nil }
        let header = 1 + nameLength + 1
        guard let type = decoded.osType(at: header), let creator = decoded.osType(at: header + 4),
              let flags = decoded.be16(at: header + 8), let dataLength = decoded.be32(at: header + 10),
              let resourceLength = decoded.be32(at: header + 14) else { return nil }
        let dataStart = header + 20
        let resourceStart = dataStart + dataLength + 2
        guard let dataFork = decoded.subdata(checked: dataStart..<(dataStart + dataLength)),
              let resourceFork = decoded.subdata(checked: resourceStart..<(resourceStart + resourceLength)) else { return nil }
        return MacFile(name: name, type: type, creator: creator, finderFlags: flags, dataFork: dataFork,
                       resourceFork: resourceFork.isEmpty ? nil : resourceFork)
    }
}
