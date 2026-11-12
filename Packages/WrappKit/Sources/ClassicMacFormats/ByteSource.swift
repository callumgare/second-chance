//
//  ByteSource.swift
//  ClassicMacFormats
//
//  Reading a disc or volume by ranges rather than whole: a mapped file, a
//  slice of one, or a view that strips a raw CD's sector headers. The disc
//  and volume readers (HFS here, ISO 9660 in ProgramImages) read only what
//  they need, so a 650 MB disc is never copied to be looked into.

import Foundation

/// Bytes that can be read by range, counted from zero.
nonisolated public protocol ByteSource: Sendable {
    var count: Int { get }
    /// Nil if any of `range` is past the end.
    func read(_ range: Range<Int>) -> Data?
}

extension Data: ByteSource {
    nonisolated public func read(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count, range.lowerBound <= range.upperBound else { return nil }
        return self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)]
    }
}

/// A window onto another source: a partition, a volume after a header.
nonisolated public struct ByteSlice: ByteSource {
    public let base: any ByteSource
    public let offset: Int
    public let count: Int

    public init(_ base: any ByteSource, offset: Int, count: Int? = nil) {
        self.base = base
        self.offset = max(0, offset)
        self.count = max(0, min(count ?? base.count - offset, base.count - offset))
    }

    public func read(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return base.read((offset + range.lowerBound)..<(offset + range.upperBound))
    }
}

extension ByteSource {
    nonisolated public func be16(at offset: Int) -> Int? {
        read(offset..<(offset + 2)).flatMap { $0.be16(at: 0) }
    }

    nonisolated public func be32(at offset: Int) -> Int? {
        read(offset..<(offset + 4)).flatMap { $0.be32(at: 0) }
    }
}

extension Data {
    /// Big-endian, from a zero-based offset; nil past the end.
    nonisolated public func be8(at offset: Int) -> Int? {
        guard offset >= 0, offset < count else { return nil }
        return Int(self[startIndex + offset])
    }

    nonisolated public func be16(at offset: Int) -> Int? {
        guard let high = be8(at: offset), let low = be8(at: offset + 1) else { return nil }
        return high << 8 | low
    }

    nonisolated public func be32(at offset: Int) -> Int? {
        guard let high = be16(at: offset), let low = be16(at: offset + 2) else { return nil }
        return high << 16 | low
    }

    /// A signed big-endian 16-bit number (a resource ID).
    nonisolated public func be16Signed(at offset: Int) -> Int? {
        be16(at: offset).map { Int(Int16(truncatingIfNeeded: $0)) }
    }

    /// Four bytes as a Mac OSType ('ICN#', 'APPL').
    nonisolated public func osType(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return MacRoman.string(self[(startIndex + offset)..<(startIndex + offset + 4)])
    }

    /// A Pascal string (a length byte, then that many Mac Roman bytes).
    nonisolated public func pascalString(at offset: Int, maxLength: Int = 255) -> String? {
        guard let length = be8(at: offset), length <= maxLength, offset + 1 + length <= count else { return nil }
        return MacRoman.string(self[(startIndex + offset + 1)..<(startIndex + offset + 1 + length)])
    }

    /// The bytes in `range` from zero, if they are all there.
    nonisolated public func subdata(checked range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count, range.lowerBound <= range.upperBound else { return nil }
        return self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)]
    }
}

nonisolated public enum MacRoman {
    public static func string<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        String(data: Data(bytes), encoding: .macOSRoman) ?? String(decoding: bytes, as: UTF8.self)
    }
}
