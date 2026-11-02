import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PuppeteerCore

/// The picture matching WrappPuppeteer drives games with, on pictures drawn
/// here: fingerprints of splash screens, the template search for a button,
/// and the check that a 4:3 picture sits between dark bars.
@Suite("Picture matching")
struct MatchingTests {
    /// A width × height picture, black, with `rectangles` drawn in their colours.
    private static func picture(width: Int, height: Int,
                                _ rectangles: [(CGRect, (CGFloat, CGFloat, CGFloat))] = []) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (rect, (red, green, blue)) in rectangles {
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(rect)
        }
        return try #require(context.makeImage())
    }

    private static func save(_ image: CGImage, as name: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url.path
    }

    @Test("A picture's fingerprint is nearest itself, and far from a different one")
    func fingerprints() throws {
        let logo = try Self.picture(width: 640, height: 480, [(CGRect(x: 200, y: 150, width: 240, height: 180), (1, 0.8, 0))])
        let similar = try Self.picture(width: 640, height: 480, [(CGRect(x: 202, y: 150, width: 240, height: 180), (1, 0.8, 0))])
        let other = try Self.picture(width: 640, height: 480, [(CGRect(x: 0, y: 0, width: 320, height: 480), (0, 0.4, 1))])
        let print = try #require(ImageFingerprint(image: logo))
        #expect(print.distance(to: print) == 0)
        #expect(print.distance(to: try #require(ImageFingerprint(image: similar))) < 0.08)
        #expect(print.distance(to: try #require(ImageFingerprint(image: other))) > 0.08)
    }

    @Test("A button is found where it is drawn")
    func templateMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matching-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A red button with a white mark, in the bottom-right corner of a screen.
        let button = try Self.picture(width: 60, height: 30, [
            (CGRect(x: 0, y: 0, width: 60, height: 30), (0.9, 0.1, 0.1)),
            (CGRect(x: 20, y: 10, width: 20, height: 10), (1, 1, 1)),
        ])
        let screen = try Self.picture(width: 800, height: 600, [
            (CGRect(x: 100, y: 400, width: 200, height: 100), (0.2, 0.5, 0.2)),
            (CGRect(x: 700, y: 30, width: 60, height: 30), (0.9, 0.1, 0.1)),
            (CGRect(x: 720, y: 40, width: 20, height: 10), (1, 1, 1)),
        ])
        let found = try #require(TemplateMatcher.findImage(Self.save(button, as: "button.png", in: directory),
                                                           in: Self.save(screen, as: "screen.png", in: directory)))
        // Top-left origin: the button's top is 600 - 30 - 30 = 540 down.
        #expect(abs(found.midX - 730) < 4)
        #expect(abs(found.midY - 555) < 4)
    }

    @Test("A 4:3 picture between dark bars is framed rightly; light in a bar is found")
    func framing() throws {
        // 1600 × 900, with the 4:3 picture (1200 wide) in the middle.
        let framed = try Self.picture(width: 1600, height: 900, [(CGRect(x: 200, y: 0, width: 1200, height: 900), (0.6, 0.6, 0.6))])
        #expect(PictureFrameCheck.findings(in: framed, pictureAspect: 4.0 / 3.0).isEmpty)
        let stretched = try Self.picture(width: 1600, height: 900, [(CGRect(x: 0, y: 0, width: 1600, height: 900), (0.6, 0.6, 0.6))])
        #expect(!PictureFrameCheck.findings(in: stretched, pictureAspect: 4.0 / 3.0).isEmpty)
    }
}
