import CoreGraphics
import Foundation
import ImageIO

/// Whether two pictures look the same, for keeping a retaken screenshot out
/// of a commit when only its encoding changed.
enum ImageComparison {
    enum Verdict: Equatable {
        case same
        case different
        /// The new picture has fewer pixels: taken on a display of a lower
        /// scale, which isn't a change worth keeping.
        case lowerResolution
    }

    /// How much a channel may differ before a pixel counts as changed, and
    /// how many pixels may change before the pictures differ. Measured: two
    /// captures of the same window, on the same Mac, a macOS update apart,
    /// differed by at most 13 in any channel and in no pixel past 16; two
    /// digits of a countdown changing ("1m 34s" to "1m 40s") changed 313
    /// pixels, a 0.025% share. So a handful of pixels, not a share of the
    /// picture: a single changed character is well over a hundred.
    static let channelTolerance = 16
    static let changedPixelsAllowed = 8

    static func compare(_ old: Data, _ new: Data) -> Verdict {
        guard let oldImage = image(old), let newImage = image(new) else { return .different }
        if newImage.width * newImage.height < oldImage.width * oldImage.height { return .lowerResolution }
        guard oldImage.width == newImage.width, oldImage.height == newImage.height,
              let oldPixels = rgba(oldImage), let newPixels = rgba(newImage) else { return .different }
        var changed = 0
        for pixel in stride(from: 0, to: oldPixels.count, by: 4) {
            for channel in 0..<4 where abs(Int(oldPixels[pixel + channel]) - Int(newPixels[pixel + channel])) > channelTolerance {
                changed += 1
                break
            }
        }
        return changed <= changedPixelsAllowed ? .same : .different
    }

    private static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}
