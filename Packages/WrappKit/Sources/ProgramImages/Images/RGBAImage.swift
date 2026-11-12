//
//  RGBAImage.swift
//  ProgramImages
//
//  A decoded image: 8-bit RGBA, not premultiplied, rows top down. Every
//  decoder ends here, so dedupe, hashing and PNG writing need know nothing
//  of ICO, PICT or PCX.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    /// width × height × 4 bytes: R, G, B, A.
    public var pixels: [UInt8]
    /// The source's bits per pixel (1 for a black-and-white icon, 32 for one
    /// with alpha), as the format said; 0 when it didn't.
    public var bitDepth: Int

    /// The largest image decoded, a side and in all: a crafted file can
    /// claim any size.
    public static let maxSide = 16_384
    public static let maxPixels = 64 * 1024 * 1024

    public init?(width: Int, height: Int, pixels: [UInt8], bitDepth: Int) {
        guard width > 0, height > 0, width <= Self.maxSide, height <= Self.maxSide,
              width * height <= Self.maxPixels, pixels.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
        self.bitDepth = bitDepth
    }

    /// A blank (transparent) image, to draw into.
    public static func blank(width: Int, height: Int, bitDepth: Int) -> RGBAImage? {
        guard width > 0, height > 0, width <= maxSide, height <= maxSide, width * height <= maxPixels else { return nil }
        return RGBAImage(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4),
                         bitDepth: bitDepth)
    }

    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        let index = (y * width + x) * 4
        pixels[index] = r
        pixels[index + 1] = g
        pixels[index + 2] = b
        pixels[index + 3] = a
    }

    // The measures below loop over the buffer by hand: a crawl measures
    // hundreds of pictures at its end, and in a debug build a generic
    // `stride` or a dictionary per pixel takes seconds over them.

    public var hasAlpha: Bool { anyAlpha { $0 != 255 } }

    /// Whether every pixel is see-through: a blank mask, nothing to show.
    public var isFullyTransparent: Bool { !anyAlpha { $0 != 0 } }

    private func anyAlpha(_ test: (UInt8) -> Bool) -> Bool {
        pixels.withUnsafeBufferPointer { buffer in
            var index = 3
            while index < buffer.count {
                if test(buffer[index]) { return true }
                index += 4
            }
            return false
        }
    }

    /// Every `step`th pixel that is mostly opaque, as its R, G, B: at most
    /// about 65,536 of them.
    private func forEachOpaqueSample(_ body: (UInt8, UInt8, UInt8) -> Void) {
        let count = width * height
        let step = max(1, count / 65_536)
        pixels.withUnsafeBufferPointer { buffer in
            var pixel = 0
            while pixel < count {
                let index = pixel * 4
                if buffer[index + 3] > 127 { body(buffer[index], buffer[index + 1], buffer[index + 2]) }
                pixel += step
            }
        }
    }

    /// The commonest colour, quantised to 5 bits a channel, among the
    /// opaque samples: its bin, how many fell in it, and how many in all.
    private var dominantBin: (bin: Int, count: Int, opaque: Int) {
        var counts = [Int](repeating: 0, count: 1 << 15)
        var opaque = 0
        var best = 0
        var bestCount = 0
        counts.withUnsafeMutableBufferPointer { counts in
            forEachOpaqueSample { r, g, b in
                let bin = Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3)
                counts[bin] += 1
                opaque += 1
                // the first bin to reach the top count keeps it
                if counts[bin] > bestCount || (counts[bin] == bestCount && bin < best) {
                    best = bin
                    bestCount = counts[bin]
                }
            }
        }
        return (best, bestCount, opaque)
    }

    // MARK: - From and to Core Graphics

    /// Drawn into an RGBA context (premultiplied, as Core Graphics draws),
    /// then unpremultiplied.
    public init?(cgImage: CGImage, bitDepth: Int? = nil) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, width <= Self.maxSide, height <= Self.maxSide,
              width * height <= Self.maxPixels else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            if alpha == 0 {
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
            } else if alpha < 255 {
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        self.width = width
        self.height = height
        self.pixels = pixels
        self.bitDepth = bitDepth ?? cgImage.bitsPerPixel
    }

    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func pngData() -> Data? {
        guard let image = cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Hashes

    /// SHA-256 of the size and the pixels, with every fully transparent
    /// pixel's colour cleared: the same icon found as an .ico, in a program
    /// and in an MSI hashes the same, whatever was under its mask.
    public var pixelHash: String {
        var hasher = SHA256()
        withUnsafeBytes(of: UInt32(width).bigEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: UInt32(height).bigEndian) { hasher.update(bufferPointer: $0) }
        var normalised = pixels
        normalised.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                if buffer[index + 3] == 0 {
                    buffer[index] = 0
                    buffer[index + 1] = 0
                    buffer[index + 2] = 0
                }
                index += 4
            }
        }
        normalised.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A 64-bit difference hash: the image, over mid grey, shrunk to 9×8
    /// by averaging (all of a small image, a sample of a big one), each bit
    /// whether a cell is brighter than the one to its right. Sizes and
    /// depths of the same art come out close.
    public var differenceHash: UInt64 {
        var cells = [Double](repeating: 0, count: 9 * 8)
        var weights = [Double](repeating: 0, count: 9 * 8)
        // At most about 256 rows and columns, evenly spread: a cell's
        // average barely moves, and a big picture costs little more.
        let stepY = max(1, height / 256)
        let stepX = max(1, width / 256)
        pixels.withUnsafeBufferPointer { buffer in
            var y = 0
            while y < height {
                let cellY = min(7, y * 8 / height)
                var x = 0
                while x < width {
                    let cellX = min(8, x * 9 / width)
                    let index = (y * width + x) * 4
                    let alpha = Double(buffer[index + 3]) / 255
                    let luma = 0.299 * Double(buffer[index]) + 0.587 * Double(buffer[index + 1]) + 0.114 * Double(buffer[index + 2])
                    cells[cellY * 9 + cellX] += luma * alpha + 128 * (1 - alpha)
                    weights[cellY * 9 + cellX] += 1
                    x += stepX
                }
                y += stepY
            }
        }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                let left = cells[row * 9 + column] / max(weights[row * 9 + column], 1)
                let right = cells[row * 9 + column + 1] / max(weights[row * 9 + column + 1], 1)
                hash = hash << 1 | (left > right ? 1 : 0)
            }
        }
        return hash
    }

    // MARK: - Measures for ranking

    /// The share of opaque pixels that are the commonest colour (quantised
    /// to 5 bits a channel): near 1 for a blank or flat image.
    public var dominantColourShare: Double {
        let top = dominantBin
        guard top.opaque > 0 else { return 1 }
        return Double(top.count) / Double(top.opaque)
    }

    /// How far the pixels in the commonest colour's bin (as `dominantColourShare` bins them) stray from their own
    /// mean: the largest channel's standard deviation, 0–255. Near 0 for one shade (with a JPEG's noise, a little
    /// more); a few levels for two close shades sharing a bin, as a pinstripe of two dark blues does.
    public var dominantColourSpread: Double {
        let top = dominantBin
        guard top.count > 0 else { return 0 }
        var n = 0.0
        var sum = (0.0, 0.0, 0.0)
        var squares = (0.0, 0.0, 0.0)
        forEachOpaqueSample { r, g, b in
            guard Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3) == top.bin else { return }
            let (vr, vg, vb) = (Double(r), Double(g), Double(b))
            n += 1
            sum.0 += vr; sum.1 += vg; sum.2 += vb
            squares.0 += vr * vr; squares.1 += vg * vg; squares.2 += vb * vb
        }
        func deviation(_ s: Double, _ q: Double) -> Double {
            let mean = s / n
            return max(0, q / n - mean * mean).squareRoot()
        }
        return max(deviation(sum.0, squares.0), deviation(sum.1, squares.1), deviation(sum.2, squares.2))
    }

    /// Mean brightness of the opaque pixels, 0–255.
    public var meanLuma: Double {
        var total = 0.0
        var count = 0
        forEachOpaqueSample { r, g, b in
            total += 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            count += 1
        }
        return count > 0 ? total / Double(count) : 0
    }
}
