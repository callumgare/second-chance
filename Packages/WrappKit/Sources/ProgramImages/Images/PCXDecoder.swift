//
//  PCXDecoder.swift
//  ProgramImages
//
//  ZSoft PCX, the DOS era's commonest image file, which ImageIO doesn't
//  read: a 128-byte header, run-length rows plane by plane, and for 8-bit
//  images a 256-colour palette after a 0x0C byte at the end. Handles 1-bit
//  (mono or 16-colour EGA in four planes), 8-bit paletted and 24-bit (three
//  planes). Bounds-checked: a damaged file gives nil.

import Foundation
import WindowsFormats

nonisolated public enum PCXDecoder {
    public static func looksLike(_ data: Data) -> Bool {
        data.u8(at: 0) == 0x0A && [0, 2, 3, 4, 5].contains(data.u8(at: 1) ?? -1) && data.u8(at: 2) == 1
            && [1, 2, 4, 8].contains(data.u8(at: 3) ?? -1)
    }

    public static func decode(_ data: Data) -> RGBAImage? {
        guard data.count > 128, looksLike(data), let bits = data.u8(at: 3), let xMin = data.u16(at: 4), let yMin = data.u16(at: 6),
              let xMax = data.u16(at: 8), let yMax = data.u16(at: 10), let planes = data.u8(at: 65),
              let bytesPerLine = data.u16(at: 66), xMax >= xMin, yMax >= yMin else { return nil }
        let width = xMax - xMin + 1
        let height = yMax - yMin + 1
        guard bytesPerLine * 8 >= width * bits, (1...4).contains(planes),
              var image = RGBAImage.blank(width: width, height: height, bitDepth: bits * planes) else { return nil }

        // Run-length decode every row's planes.
        let lineBytes = bytesPerLine * planes
        var decoded = [UInt8]()
        decoded.reserveCapacity(lineBytes * height)
        let bytes = [UInt8](data)
        var position = 128
        while decoded.count < lineBytes * height, position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte >= 0xC0 {
                guard position < bytes.count else { break }
                decoded += [UInt8](repeating: bytes[position], count: Int(byte & 0x3F))
                position += 1
            } else {
                decoded.append(byte)
            }
        }
        guard decoded.count >= lineBytes * height else { return nil }

        var palette: [(UInt8, UInt8, UInt8)] = (0..<16).map { index in
            (bytes[16 + index * 3], bytes[17 + index * 3], bytes[18 + index * 3])
        }
        if bits == 8, planes == 1 {
            let start = bytes.count - 769
            guard start >= 128, bytes[start] == 0x0C else { return nil }
            palette = (0..<256).map { index in
                (bytes[start + 1 + index * 3], bytes[start + 2 + index * 3], bytes[start + 3 + index * 3])
            }
        } else if bits == 1, planes == 1 {
            palette = [(0, 0, 0), (255, 255, 255)]
        }

        for y in 0..<height {
            let line = y * lineBytes
            for x in 0..<width {
                switch (bits, planes) {
                case (8, 3), (8, 4):
                    image.set(x, y, decoded[line + x], decoded[line + bytesPerLine + x],
                              decoded[line + 2 * bytesPerLine + x], planes == 4 ? decoded[line + 3 * bytesPerLine + x] : 255)
                case (8, 1):
                    let (r, g, b) = palette[Int(decoded[line + x])]
                    image.set(x, y, r, g, b, 255)
                case (1, _):
                    var index = 0
                    for plane in 0..<planes where decoded[line + plane * bytesPerLine + x / 8] >> (7 - x % 8) & 1 == 1 {
                        index |= 1 << plane
                    }
                    let (r, g, b) = palette[min(index, palette.count - 1)]
                    image.set(x, y, r, g, b, 255)
                case (2, 1), (4, 1):
                    let bitOffset = x * bits
                    let index = Int(decoded[line + bitOffset / 8]) >> (8 - bits - bitOffset % 8) & ((1 << bits) - 1)
                    let (r, g, b) = palette[min(index, palette.count - 1)]
                    image.set(x, y, r, g, b, 255)
                default:
                    return nil
                }
            }
        }
        return image
    }
}
