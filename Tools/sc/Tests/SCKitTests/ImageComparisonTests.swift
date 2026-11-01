import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SCKit

@Suite("Whether a retaken screenshot looks different")
struct ImageComparisonTests {
    /// A grey picture `width` by `height`, with the pixels `changed` gives
    /// set to `value` instead.
    private func png(width: Int = 100, height: Int = 100, grey: UInt8 = 128,
                     changed: Int = 0, value: UInt8 = 0) -> Data {
        var pixels = [UInt8](repeating: grey, count: width * height * 4)
        for pixel in 0..<width * height { pixels[pixel * 4 + 3] = 255 }
        for pixel in 0..<changed { pixels[pixel * 4] = value }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("The same picture, or one changed by a few shades, is the same")
    func same() {
        #expect(ImageComparison.compare(png(), png()) == .same)
        #expect(ImageComparison.compare(png(), png(changed: 10_000, value: 136)) == .same)
    }

    @Test("A few pixels changed a lot pass; more than a tenth of a percent don't")
    func changedShare() {
        #expect(ImageComparison.compare(png(), png(changed: 10, value: 0)) == .same)
        #expect(ImageComparison.compare(png(), png(changed: 11, value: 0)) == .different)
    }

    @Test("A smaller picture is a lower resolution, a larger one different")
    func sizes() {
        #expect(ImageComparison.compare(png(), png(width: 50, height: 50)) == .lowerResolution)
        #expect(ImageComparison.compare(png(width: 50, height: 50), png()) == .different)
    }
}
