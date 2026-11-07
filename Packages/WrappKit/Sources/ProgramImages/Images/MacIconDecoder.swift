//
//  MacIconDecoder.swift
//  ProgramImages
//
//  Classic Mac icon resources, decoded: 'ICN#' (32×32 1-bit and its mask),
//  'ics#' (16×16), 'icl4'/'icl8' and 'ics4'/'ics8' (4- and 8-bit, in the
//  system's fixed palettes, masked by the ICN#/ics# of the same ID), 'ICON'
//  and 'SICN' (1-bit, unmasked), 'cicn' (a colour icon with its own colour
//  table), and 'icns' (Mac OS 8.5's, which ImageIO reads). Inside
//  Macintosh: Imaging With QuickDraw has the layouts; resource_dasm was the
//  reference.

import ClassicMacFormats
import Foundation

nonisolated public enum MacIconDecoder {
    public struct Decoded: Sendable {
        public let image: RGBAImage
        /// The resource it came from: "icl8 128".
        public let label: String
        public let type: String
    }

    /// The icon types decoded, best first.
    public static let iconTypes = ["icns", "icl8", "icl4", "ICN#", "ics8", "ics4", "ics#", "cicn", "ICON", "SICN"]

    /// Every icon of the family with resource ID `id` in `fork`: each type
    /// it has, each masked as the Finder masks it.
    public static func family(_ id: Int, in fork: ResourceFork) -> [Decoded] {
        var decoded: [Decoded] = []
        let largeMask = fork.resource("ICN#", id: id).flatMap { oneBit($0.data, offset: 128, size: 32) }
        let smallMask = fork.resource("ics#", id: id).flatMap { oneBit($0.data, offset: 32, size: 16) }
        for type in iconTypes {
            guard let resource = fork.resource(type, id: id) else { continue }
            decoded += decode(resource, largeMask: largeMask, smallMask: smallMask)
        }
        return decoded
    }

    /// One icon resource, masked by the family's mask when it has none of
    /// its own. Empty for a type that isn't an icon, or a damaged one.
    public static func decode(_ resource: MacResource, largeMask: [Bool]? = nil, smallMask: [Bool]? = nil) -> [Decoded] {
        let data = resource.data
        let label = "\(resource.type) \(resource.id)"
        // The mask isn't named in the label: "mask" in a name ranks an image down.
        func one(_ image: RGBAImage?) -> [Decoded] {
            guard let image, !image.isFullyTransparent else { return [] }
            return [Decoded(image: image, label: label, type: resource.type)]
        }
        switch resource.type {
        case "ICN#":
            return one(bitmap(oneBit(data, offset: 0, size: 32), mask: oneBit(data, offset: 128, size: 32), size: 32))
        case "ics#":
            return one(bitmap(oneBit(data, offset: 0, size: 16), mask: oneBit(data, offset: 32, size: 16), size: 16))
        case "ICON":
            return one(bitmap(oneBit(data, offset: 0, size: 32), mask: nil, size: 32))
        case "SICN":
            return (0..<min(data.count / 32, 64)).flatMap { index in
                one(bitmap(oneBit(data, offset: index * 32, size: 16), mask: nil, size: 16))
            }
        case "icl8":
            return one(indexed(data, size: 32, bits: 8, palette: MacPalettes.eightBit, mask: largeMask))
        case "icl4":
            return one(indexed(data, size: 32, bits: 4, palette: MacPalettes.fourBit, mask: largeMask))
        case "ics8":
            return one(indexed(data, size: 16, bits: 8, palette: MacPalettes.eightBit, mask: smallMask))
        case "ics4":
            return one(indexed(data, size: 16, bits: 4, palette: MacPalettes.fourBit, mask: smallMask))
        case "cicn":
            return one(colorIcon(data))
        case "icns":
            return ImageIODecoder.decode(data, typeHint: "com.apple.icns").map { image in
                Decoded(image: image, label: "\(label) \(image.width)×\(image.height)", type: "icns")
            }
        default:
            return []
        }
    }

    /// `size`×`size` 1-bit pixels from `offset`, rows of `size / 8` bytes.
    static func oneBit(_ data: Data, offset: Int, size: Int) -> [Bool]? {
        let rowBytes = size / 8
        guard let bytes = data.subdata(checked: offset..<(offset + rowBytes * size)) else { return nil }
        let array = [UInt8](bytes)
        var bits = [Bool](repeating: false, count: size * size)
        for index in 0..<size * size {
            let byte = array[index / size * rowBytes + (index % size) / 8]
            bits[index] = (byte >> UInt8(7 - index % 8)) & 1 == 1
        }
        return bits
    }

    private static func bitmap(_ bits: [Bool]?, mask: [Bool]?, size: Int) -> RGBAImage? {
        guard let bits, var image = RGBAImage.blank(width: size, height: size, bitDepth: 1) else { return nil }
        for index in 0..<size * size {
            let black = bits[index]
            let visible = mask?[index] ?? true
            let value: UInt8 = black ? 0 : 255
            image.set(index % size, index / size, value, value, value, visible ? 255 : 0)
        }
        return image
    }

    private static func indexed(_ data: Data, size: Int, bits: Int, palette: [(UInt8, UInt8, UInt8)],
                                mask: [Bool]?) -> RGBAImage? {
        let rowBytes = size * bits / 8
        guard data.count >= rowBytes * size, var image = RGBAImage.blank(width: size, height: size, bitDepth: bits)
        else { return nil }
        let array = [UInt8](data.prefix(rowBytes * size))
        for y in 0..<size {
            for x in 0..<size {
                let bitOffset = x * bits
                let index = Int(array[y * rowBytes + bitOffset / 8]) >> (8 - bits - bitOffset % 8) & ((1 << bits) - 1)
                let (r, g, b) = palette[min(index, palette.count - 1)]
                image.set(x, y, r, g, b, (mask?[y * size + x] ?? true) ? 255 : 0)
            }
        }
        return image
    }

    /// A 'cicn': a PixMap, a mask BitMap and a 1-bit BitMap (their headers,
    /// 82 bytes with the handle), then the mask's bits, the 1-bit icon's,
    /// the colour table, and the pixels.
    private static func colorIcon(_ data: Data) -> RGBAImage? {
        guard let pixRowBytes = data.be16(at: 4).map({ $0 & 0x3FFF }), let top = data.be16Signed(at: 6),
              let left = data.be16Signed(at: 8), let bottom = data.be16Signed(at: 10), let right = data.be16Signed(at: 12),
              let pixelSize = data.be16(at: 32), let maskRowBytes = data.be16(at: 54),
              let bitmapRowBytes = data.be16(at: 68) else { return nil }
        let width = right - left
        let height = bottom - top
        guard width > 0, height > 0, width <= 256, height <= 256, [1, 2, 4, 8].contains(pixelSize),
              pixRowBytes * 8 >= width * pixelSize, maskRowBytes * 8 >= width else { return nil }
        let maskStart = 82
        let bitmapStart = maskStart + maskRowBytes * height
        let tableStart = bitmapStart + bitmapRowBytes * height
        guard let tableCount = data.be16(at: tableStart + 6), tableCount < 256 else { return nil }
        var palette = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: 1 << pixelSize)
        for entry in 0...tableCount {
            let at = tableStart + 8 + entry * 8
            guard let value = data.be16(at: at), let red = data.be8(at: at + 2), let green = data.be8(at: at + 4),
                  let blue = data.be8(at: at + 6) else { return nil }
            // A device table's values are positions; otherwise its index.
            let index = (data.be16(at: tableStart + 4) ?? 0) & 0x8000 != 0 ? entry : value
            if index < palette.count { palette[index] = (UInt8(red), UInt8(green), UInt8(blue)) }
        }
        let pixelStart = tableStart + 8 + (tableCount + 1) * 8
        guard let pixels = data.subdata(checked: pixelStart..<(pixelStart + pixRowBytes * height)).map({ [UInt8]($0) }),
              let mask = data.subdata(checked: maskStart..<bitmapStart).map({ [UInt8]($0) }),
              var image = RGBAImage.blank(width: width, height: height, bitDepth: pixelSize) else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                let bitOffset = x * pixelSize
                let index = Int(pixels[y * pixRowBytes + bitOffset / 8]) >> (8 - pixelSize - bitOffset % 8)
                    & ((1 << pixelSize) - 1)
                let (r, g, b) = palette[index]
                let visible = mask[y * maskRowBytes + x / 8] >> (7 - x % 8) & 1 == 1
                image.set(x, y, r, g, b, visible ? 255 : 0)
            }
        }
        return image
    }
}

/// The Mac's standard palettes ('clut' 4 and 8), which 4- and 8-bit icons
/// are drawn in.
nonisolated public enum MacPalettes {
    public static let fourBit: [(UInt8, UInt8, UInt8)] = [
        (0xFF, 0xFF, 0xFF), (0xFC, 0xF3, 0x05), (0xFF, 0x64, 0x02), (0xDD, 0x08, 0x06),
        (0xF2, 0x08, 0x84), (0x46, 0x00, 0xA5), (0x00, 0x00, 0xD4), (0x02, 0xAB, 0xEA),
        (0x1F, 0xB7, 0x14), (0x00, 0x64, 0x11), (0x56, 0x2C, 0x05), (0x90, 0x71, 0x3A),
        (0xC0, 0xC0, 0xC0), (0x80, 0x80, 0x80), (0x40, 0x40, 0x40), (0x00, 0x00, 0x00),
    ]

    /// A 6×6×6 cube from white to black (215 entries, black left out), ramps
    /// of red, green, blue and grey (10 each), then black.
    public static let eightBit: [(UInt8, UInt8, UInt8)] = {
        let levels: [UInt8] = [0xFF, 0xCC, 0x99, 0x66, 0x33, 0x00]
        var palette: [(UInt8, UInt8, UInt8)] = []
        for index in 0..<215 {
            palette.append((levels[index / 36], levels[(index / 6) % 6], levels[index % 6]))
        }
        let ramp: [UInt8] = [0xEE, 0xDD, 0xBB, 0xAA, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11]
        palette += ramp.map { ($0, 0, 0) }
        palette += ramp.map { (0, $0, 0) }
        palette += ramp.map { (0, 0, $0) }
        palette += ramp.map { ($0, $0, $0) }
        palette.append((0, 0, 0))
        return palette
    }()
}
