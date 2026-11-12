//
//  WindowsImageDecoder.swift
//  ProgramImages
//
//  Windows' device-independent bitmaps, decoded here rather than by ImageIO
//  for the cases that matter most: an icon's image (a DIB twice its height,
//  the colour bitmap then a 1-bit AND mask, or a PNG), and an RT_BITMAP's
//  uncompressed pixels. ImageIO takes the rest (RLE, odd headers) through a
//  .bmp file header. Bounds-checked: a damaged image gives nil.

import Foundation
import WindowsFormats

nonisolated public enum WindowsImageDecoder {
    /// One image of an icon or cursor (an RT_ICON's bytes, or an entry of an
    /// .ico): a PNG, or a DIB with its mask.
    public static func decodeIconImage(_ data: Data) -> RGBAImage? {
        if data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ImageIODecoder.decode(data, maxImages: 1).first.map { image in
                var image = image
                image.bitDepth = 32
                return image
            }
        }
        return decodeDIB(data, isIcon: true)
    }

    /// An RT_BITMAP (a DIB without its file header).
    public static func decodeBitmap(_ dib: Data) -> RGBAImage? {
        if let image = decodeDIB(dib, isIcon: false) { return image }
        guard let file = DIBHeader.bmpFile(dib), let header = DIBHeader(data: dib) else { return nil }
        return ImageIODecoder.decode(file, maxImages: 1).first.map { image in
            var image = image
            image.bitDepth = header.bitCount
            return image
        }
    }

    /// Uncompressed DIBs (BI_RGB, and BI_BITFIELDS in the usual layouts);
    /// nil for anything else, which ImageIO is asked to read.
    static func decodeDIB(_ data: Data, isIcon: Bool) -> RGBAImage? {
        guard let header = DIBHeader(data: data), header.compression == 0 || header.compression == 3 else { return nil }
        let width = header.width
        let fullHeight = abs(header.height)
        let height = isIcon ? fullHeight / 2 : fullHeight
        let bottomUp = header.height > 0
        let bits = header.bitCount
        guard height > 0, var image = RGBAImage.blank(width: width, height: height, bitDepth: bits) else { return nil }

        var palette: [(UInt8, UInt8, UInt8)] = []
        let entrySize = header.paletteEntrySize
        for index in 0..<header.paletteCount {
            let at = header.headerSize + index * entrySize
            guard let blue = data.u8(at: at), let green = data.u8(at: at + 1), let red = data.u8(at: at + 2) else { break }
            palette.append((UInt8(red), UInt8(green), UInt8(blue)))
        }
        let pixelStart = header.pixelOffset
        let rowBytes = ((width * bits + 31) / 32) * 4
        guard let pixelBytes = data.bytes(in: pixelStart..<(pixelStart + rowBytes * height)) else { return nil }
        let pixels = [UInt8](pixelBytes)

        // An icon's mask follows its colour bitmap: 1 means see-through.
        var mask: [UInt8]?
        let maskRowBytes = ((width + 31) / 32) * 4
        if isIcon {
            let maskStart = pixelStart + rowBytes * height
            mask = data.bytes(in: maskStart..<(maskStart + maskRowBytes * height)).map { [UInt8]($0) }
        }
        // BI_BITFIELDS masks, after a 40-byte header or inside a larger one.
        var redMask = 0, greenMask = 0, blueMask = 0, alphaMask = 0
        if header.compression == 3 {
            redMask = data.u32(at: 40) ?? 0
            greenMask = data.u32(at: 44) ?? 0
            blueMask = data.u32(at: 48) ?? 0
            alphaMask = header.headerSize >= 56 ? data.u32(at: 52) ?? 0 : 0
        } else if bits == 16 {
            redMask = 0x7C00
            greenMask = 0x03E0
            blueMask = 0x001F
        } else if bits == 32 {
            redMask = 0xFF_0000
            greenMask = 0xFF00
            blueMask = 0xFF
            alphaMask = 0xFF00_0000
        }
        func channel(_ value: Int, _ mask: Int) -> UInt8 {
            guard mask != 0 else { return 0 }
            let shift = mask.trailingZeroBitCount
            let maximum = mask >> shift
            return UInt8(((value & mask) >> shift) * 255 / max(maximum, 1))
        }

        var anyAlpha = false
        for row in 0..<height {
            let sourceRow = bottomUp ? height - 1 - row : row
            let base = sourceRow * rowBytes
            for x in 0..<width {
                var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255
                switch bits {
                case 1, 2, 4, 8:
                    let bitOffset = x * bits
                    let byte = Int(pixels[base + bitOffset / 8])
                    let index = (byte >> (8 - bits - bitOffset % 8)) & ((1 << bits) - 1)
                    if index < palette.count { (r, g, b) = palette[index] }
                case 16:
                    let value = Int(pixels[base + x * 2]) | Int(pixels[base + x * 2 + 1]) << 8
                    r = channel(value, redMask)
                    g = channel(value, greenMask)
                    b = channel(value, blueMask)
                case 24:
                    b = pixels[base + x * 3]
                    g = pixels[base + x * 3 + 1]
                    r = pixels[base + x * 3 + 2]
                default:  // 32
                    let at = base + x * 4
                    let value = Int(pixels[at]) | Int(pixels[at + 1]) << 8 | Int(pixels[at + 2]) << 16 | Int(pixels[at + 3]) << 24
                    r = channel(value, redMask)
                    g = channel(value, greenMask)
                    b = channel(value, blueMask)
                    if alphaMask != 0 {
                        a = channel(value, alphaMask)
                        if a != 0 { anyAlpha = true }
                    }
                }
                image.set(x, row, r, g, b, a)
            }
        }
        // A 32-bit image whose alpha is all zero means its alpha isn't used:
        // opaque, then the mask.
        if bits == 32, !anyAlpha {
            for index in stride(from: 3, to: image.pixels.count, by: 4) { image.pixels[index] = 255 }
        }
        if let mask, !(bits == 32 && anyAlpha) {
            for row in 0..<height {
                let sourceRow = bottomUp ? height - 1 - row : row
                for x in 0..<width where Int(mask[sourceRow * maskRowBytes + x / 8]) >> (7 - x % 8) & 1 == 1 {
                    let index = (row * width + x) * 4
                    image.pixels[index] = 0
                    image.pixels[index + 1] = 0
                    image.pixels[index + 2] = 0
                    image.pixels[index + 3] = 0
                }
            }
        }
        return image
    }
}
