import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import PictureMatching

/// What a caller that reports for itself gets from the template search:
/// the best place with its confidence, and every match, so a target can be
/// checked to be the only one (`sc puppet do … --needle`).
@Suite("Template matches")
struct TemplateMatchesTests {
    private static let red = (0.9, 0.1, 0.1), white = (1.0, 1.0, 1.0)

    /// A width × height picture, black, with `rectangles` drawn in their
    /// colours (bottom-left origin, as Core Graphics draws).
    private static func picture(width: Int, height: Int, _ rectangles: [(CGRect, (Double, Double, Double))]) throws -> CGImage {
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

    /// A red button with a white mark at (x, y), bottom-left origin.
    private static func button(x: Double, y: Double) -> [(CGRect, (Double, Double, Double))] {
        [(CGRect(x: x, y: y, width: 30, height: 16), red), (CGRect(x: x + 10, y: y + 5, width: 10, height: 6), white)]
    }

    @Test("Two copies of a button are both found; none is at most a near miss")
    func matches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("matches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = try Self.save(Self.picture(width: 30, height: 16, Self.button(x: 0, y: 0)), as: "button.png", in: directory)
        let backdrop = [(CGRect(x: 40, y: 120, width: 100, height: 50), (0.2, 0.5, 0.2))]

        let two = try Self.save(Self.picture(width: 320, height: 240, backdrop + Self.button(x: 240, y: 190) + Self.button(x: 30, y: 20)),
                                as: "two.png", in: directory)
        let both = TemplateMatcher.matches(template, in: two, limit: 3)
        #expect(both.count == 2)
        #expect(both.allSatisfy { $0.isMatch && $0.confidence > 0.9 })
        // Top-left origin: 240 - 190 - 16 = 34 down, and 240 - 20 - 16 = 204.
        #expect(Set(both.map { Int($0.rect.minY) }) == [34, 204])

        // (Each search of a picture this small is exhaustive, and slow in a
        // debug build: so few of them.)
        let none = try Self.save(Self.picture(width: 320, height: 240, backdrop), as: "none.png", in: directory)
        if let nearest = TemplateMatcher.best(template, in: none) { #expect(!nearest.isMatch) }
    }
}
