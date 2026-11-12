//
//  ImageCarver.swift
//  ProgramImages
//
//  Images stored whole inside something unread — a game's own archive, a
//  program's overlay, a resource of its own type: found by their signatures
//  (PNG, JPEG, GIF, BMP) and followed to their ends by their own structure,
//  so a hit is a whole file, not a guess. What binwalk does, for images.

import Foundation

nonisolated public enum ImageCarver {
    public enum Kind: String, Sendable {
        case png, jpeg, gif, bmp
    }

    public struct Hit: Sendable, Equatable {
        public let kind: Kind
        public let range: Range<Int>
    }

    /// Up to `limit` images in `data`, in order, none overlapping. Images
    /// under `minimumSize` bytes (a tracking pixel, a stray signature) are
    /// left out. `stop` is asked every few megabytes, as a big file takes a
    /// while: true ends the search with what it has found so far.
    public static func carve(_ data: Data, limit: Int = 2000, minimumSize: Int = 64,
                             stop: () -> Bool = { false }) -> [Hit] {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [Hit] in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return [] }
            let count = bytes.count
            var hits: [Hit] = []
            var index = 0
            var nextCheck = 0
            while index + 8 < count, hits.count < limit {
                if index >= nextCheck {
                    if stop() { break }
                    nextCheck = index + (4 << 20)
                }
                // Most bytes start nothing: pass them by quickly (a raw
                // pointer, not the buffer's checked subscript).
                let last = min(count - 8, nextCheck)
                while index < last {
                    let byte = base[index]
                    if byte == 0x89 || byte == 0xFF || byte == 0x47 || byte == 0x42 { break }
                    index += 1
                }
                guard index < last else { continue }
                let byte = bytes[index]
                var end: Int?
                var kind = Kind.png
                switch byte {
                case 0x89 where bytes[index + 1] == 0x50 && bytes[index + 2] == 0x4E && bytes[index + 3] == 0x47:
                    end = pngEnd(bytes, from: index)
                    kind = .png
                case 0xFF where bytes[index + 1] == 0xD8 && bytes[index + 2] == 0xFF:
                    end = jpegEnd(bytes, from: index)
                    kind = .jpeg
                case 0x47 where bytes[index + 1] == 0x49 && bytes[index + 2] == 0x46 && bytes[index + 3] == 0x38:
                    end = gifEnd(bytes, from: index)
                    kind = .gif
                case 0x42 where bytes[index + 1] == 0x4D:
                    end = bmpEnd(bytes, from: index)
                    kind = .bmp
                default:
                    break
                }
                if let end, end - index >= minimumSize {
                    hits.append(Hit(kind: kind, range: index..<end))
                    index = end
                } else {
                    index += 1
                }
            }
            return hits
        }
    }

    private static func be32(_ bytes: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int {
        Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
    }

    private static func le32(_ bytes: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }

    /// The signature, then chunks (length, type, data, CRC) to IEND; the
    /// first must be IHDR.
    private static func pngEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard start + 33 <= bytes.count, (0..<8).allSatisfy({ bytes[start + $0] == signature[$0] }),
              be32(bytes, start + 12) == 0x4948_4452 else { return nil }  // IHDR
        var at = start + 8
        for _ in 0..<100_000 {
            guard at + 12 <= bytes.count else { return nil }
            let length = be32(bytes, at)
            let type = be32(bytes, at + 4)
            guard length < 1 << 30, at + 12 + length <= bytes.count else { return nil }
            at += 12 + length
            if type == 0x4945_4E44 { return at }  // IEND
        }
        return nil
    }

    /// SOI, then marker segments to the start of scan, then entropy-coded
    /// data to EOI (an FF not followed by 00 or a restart marker).
    private static func jpegEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var at = start + 2
        var segments = 0
        while at + 4 <= bytes.count, segments < 1000 {
            guard bytes[at] == 0xFF else { return nil }
            let marker = bytes[at + 1]
            if marker == 0xFF { at += 1; continue }
            if marker == 0xD9 { return at + 2 }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { at += 2; continue }
            let length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard length >= 2 else { return nil }
            at += 2 + length
            segments += 1
            if marker == 0xDA {
                // Entropy-coded data, which may hold more scans.
                let limit = min(bytes.count - 1, at + (64 << 20))
                while at < limit {
                    if bytes[at] == 0xFF {
                        let next = bytes[at + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) || next == 0xFF { at += 1; continue }
                        break
                    }
                    at += 1
                }
                guard at < limit else { return nil }
            }
        }
        return nil
    }

    /// The header and screen descriptor, its colour table, then blocks
    /// (extensions and images, each in sub-blocks) to the trailer.
    private static func gifEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start + 13 <= bytes.count, bytes[start + 4] == 0x37 || bytes[start + 4] == 0x39,
              bytes[start + 5] == 0x61 else { return nil }
        let width = Int(bytes[start + 6]) | Int(bytes[start + 7]) << 8
        let height = Int(bytes[start + 8]) | Int(bytes[start + 9]) << 8
        guard width > 0, height > 0 else { return nil }
        let flags = bytes[start + 10]
        var at = start + 13 + (flags & 0x80 != 0 ? 3 << ((Int(flags) & 7) + 1) : 0)
        func skipSubBlocks() -> Bool {
            for _ in 0..<1_000_000 {
                guard at < bytes.count else { return false }
                let size = Int(bytes[at])
                at += 1 + size
                if size == 0 { return true }
            }
            return false
        }
        for _ in 0..<100_000 {
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case 0x3B:
                return at + 1
            case 0x21:
                at += 2
                guard skipSubBlocks() else { return nil }
            case 0x2C:
                guard at + 10 <= bytes.count else { return nil }
                let local = bytes[at + 9]
                at += 10 + (local & 0x80 != 0 ? 3 << ((Int(local) & 7) + 1) : 0) + 1  // + LZW code size
                guard skipSubBlocks() else { return nil }
            default:
                return nil
            }
        }
        return nil
    }

    /// "BM", the file's size, reserved zeros, the pixels' offset, and a DIB
    /// header of a known size and sane dimensions.
    private static func bmpEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start + 30 <= bytes.count else { return nil }
        let size = le32(bytes, start + 2)
        let reserved = le32(bytes, start + 6)
        let pixels = le32(bytes, start + 10)
        let header = le32(bytes, start + 14)
        guard reserved == 0, [12, 40, 52, 56, 108, 124].contains(header), pixels >= 14 + header, pixels < size,
              size <= bytes.count - start, size < 256 << 20 else { return nil }
        let width = header == 12 ? Int(bytes[start + 18]) | Int(bytes[start + 19]) << 8 : le32(bytes, start + 18)
        let height = header == 12 ? Int(bytes[start + 20]) | Int(bytes[start + 21]) << 8
            : abs(Int(Int32(truncatingIfNeeded: le32(bytes, start + 22))))
        let planes = header == 12 ? Int(bytes[start + 22]) : Int(bytes[start + 26])
        guard width > 0, width <= 16384, height > 0, height <= 16384, planes == 1 else { return nil }
        return start + size
    }
}
