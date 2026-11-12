import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An RGBA image, 8 bits a channel, straight (not premultiplied) alpha, rows top first.
/// The engine's one picture type: Sendable, easy to loop over, and converted to and from CGImage at the edges.
nonisolated public struct Bitmap: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
        if fill != (0, 0, 0, 0) {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = fill.0; pixels[i + 1] = fill.1; pixels[i + 2] = fill.2; pixels[i + 3] = fill.3
            }
        }
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    @inline(__always) public func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    public func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[index(x, y) + 3] }

    // MARK: CGImage

    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0, w * h <= 64_000_000 else { return nil }
        var premul = [UInt8](repeating: 0, count: w * h * 4)
        let ok = premul.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: Bitmap.unpremultiply(premul))
    }

    public var cgImage: CGImage? {
        let premul = Bitmap.premultiply(pixels)
        guard let provider = CGDataProvider(data: Data(premul) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func premultiply(_ p: [UInt8]) -> [UInt8] {
        var out = p
        for i in stride(from: 0, to: p.count, by: 4) {
            let a = Int(p[i + 3])
            if a == 255 { continue }
            out[i] = UInt8((Int(p[i]) * a + 127) / 255)
            out[i + 1] = UInt8((Int(p[i + 1]) * a + 127) / 255)
            out[i + 2] = UInt8((Int(p[i + 2]) * a + 127) / 255)
        }
        return out
    }

    static func unpremultiply(_ p: [UInt8]) -> [UInt8] {
        var out = p
        for i in stride(from: 0, to: p.count, by: 4) {
            let a = Int(p[i + 3])
            if a == 255 || a == 0 { continue }
            out[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
            out[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
            out[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
        }
        return out
    }

    // MARK: Files

    /// Reads any image ImageIO can (an .ico or .icns at its largest size).
    public static func load(_ url: URL) -> Bitmap? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var best = 0, bestArea = -1
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w * h > bestArea { bestArea = w * h; best = i }
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, best, nil) else { return nil }
        return Bitmap(cgImage: cg)
    }

    /// A small copy straight from the file (ImageIO decodes at the smaller size: fast even for huge scans).
    public static func loadThumbnail(_ url: URL, maxPixel: Int) -> Bitmap? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return load(url) }
        return Bitmap(cgImage: cg)
    }

    public func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public func writePNG(to url: URL) throws {
        guard let data = pngData() else { throw IconLabError.imageEncoding(url.lastPathComponent) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Geometry

    /// Scaled to a new size; `pixel` keeps hard pixels (nearest neighbour).
    public func resized(width w: Int, height h: Int, pixel: Bool = false) -> Bitmap {
        let w = max(1, w), h = max(1, h)
        if w == width && h == height { return self }
        if pixel { return nearest(width: w, height: h) }
        guard let cg = cgImage else { return self }
        return Bitmap.draw(width: w, height: h) { ctx in
            ctx.interpolationQuality = .high
            ctx.drawUpright(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func nearest(width w: Int, height h: Int) -> Bitmap {
        var out = Bitmap(width: w, height: h)
        for y in 0..<h {
            let sy = min(height - 1, y * height / h)
            for x in 0..<w {
                let sx = min(width - 1, x * width / w)
                let s = index(sx, sy), d = out.index(x, y)
                out.pixels[d] = pixels[s]; out.pixels[d + 1] = pixels[s + 1]
                out.pixels[d + 2] = pixels[s + 2]; out.pixels[d + 3] = pixels[s + 3]
            }
        }
        return out
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> Bitmap {
        var out = Bitmap(width: w, height: h)
        for yy in 0..<out.height {
            let sy = y + yy
            guard sy >= 0, sy < height else { continue }
            for xx in 0..<out.width {
                let sx = x + xx
                guard sx >= 0, sx < width else { continue }
                let s = index(sx, sy), d = out.index(xx, yy)
                out.pixels[d] = pixels[s]; out.pixels[d + 1] = pixels[s + 1]
                out.pixels[d + 2] = pixels[s + 2]; out.pixels[d + 3] = pixels[s + 3]
            }
        }
        return out
    }

    /// The box of pixels with alpha above `threshold`, or nil when there are none.
    public func alphaBox(threshold: UInt8 = 8) -> (x: Int, y: Int, w: Int, h: Int)? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for y in 0..<height {
            for x in 0..<width where pixels[index(x, y) + 3] > threshold {
                if x < x0 { x0 = x }; if x > x1 { x1 = x }
                if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
        }
        return x1 < 0 ? nil : (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    /// Draw into a new transparent bitmap with Core Graphics (origin top-left, y down).
    public static func draw(width w: Int, height h: Int, _ body: (CGContext) -> Void) -> Bitmap {
        let w = max(1, w), h = max(1, h)
        var premul = [UInt8](repeating: 0, count: w * h * 4)
        premul.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            body(ctx)
        }
        return Bitmap(width: w, height: h, pixels: unpremultiply(premul))
    }

    /// This bitmap drawn over another (source-over), at a rect in the other's space, optionally rotated about its
    /// centre (degrees, clockwise) and faded.
    public func composite(onto base: inout Bitmap, rect: CGRect, rotation: Double = 0, opacity: Double = 1, pixel: Bool = false) {
        guard let cg = cgImage, let baseCG = base.cgImage else { return }
        base = Bitmap.draw(width: base.width, height: base.height) { ctx in
            ctx.drawUpright(baseCG, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            ctx.interpolationQuality = pixel ? .none : .high
            ctx.setAlpha(opacity)
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: rotation * .pi / 180)
            // The context is flipped (y down); CGImage draws upright in an unflipped space, so flip locally.
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }
    }

    // MARK: Alpha

    /// Alpha multiplied by a mask's value (its alpha, or its luminance when `luminance`), sizes must match.
    public mutating func multiplyAlpha(by mask: Bitmap, luminance: Bool = false) {
        guard mask.width == width, mask.height == height else { return }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let m = luminance ? Int(mask.pixels[i]) : Int(mask.pixels[i + 3])
            pixels[i + 3] = UInt8((Int(pixels[i + 3]) * m + 127) / 255)
        }
    }

    /// A grey mask (value in every channel, opaque) from this bitmap's alpha.
    public var alphaAsMask: Bitmap {
        var out = Bitmap(width: width, height: height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            out.pixels[i] = a; out.pixels[i + 1] = a; out.pixels[i + 2] = a; out.pixels[i + 3] = 255
        }
        return out
    }

    /// Flattened over a plain colour (opaque).
    public func flattened(over bg: RGB = RGB(255, 255, 255)) -> Bitmap {
        var out = self
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            out.pixels[i] = UInt8((Double(pixels[i]) * a + Double(bg.r) * (1 - a)).rounded())
            out.pixels[i + 1] = UInt8((Double(pixels[i + 1]) * a + Double(bg.g) * (1 - a)).rounded())
            out.pixels[i + 2] = UInt8((Double(pixels[i + 2]) * a + Double(bg.b) * (1 - a)).rounded())
            out.pixels[i + 3] = 255
        }
        return out
    }

    @inline(__always) public func luma(_ i: Int) -> Double {
        0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
    }
}

nonisolated extension CGContext {
    /// Draws an image the right way up in a flipped (y-down) context, as `Bitmap.draw` gives.
    public func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        restoreGState()
    }
}

nonisolated public enum IconLabError: Error, CustomStringConvertible {
    case imageEncoding(String)
    case notFound(String)
    case invalid(String)
    case tool(String)

    public var description: String {
        switch self {
        case .imageEncoding(let s): "couldn't encode \(s)"
        case .notFound(let s): "not found: \(s)"
        case .invalid(let s): "invalid: \(s)"
        case .tool(let s): s
        }
    }
}
