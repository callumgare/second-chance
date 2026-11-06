import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PictureMatching

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

@Suite("A needle region's search options")
struct RegionSearchOptionsTests {
    @Test("Nothing said is the whole screenshot at the template's own size, in luminance")
    func defaults() {
        let options = TemplateMatchOptions(regionSearch: nil, heightFraction: nil, scales: nil, grayscale: nil)
        #expect(options.searchRegion == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(options.templateHeightFraction == nil)
        #expect(options.scaleVariations == [1.0])
        #expect(options.grayscale == .luminance)
    }

    @Test("What a region says is what's searched")
    func given() {
        let options = TemplateMatchOptions(regionSearch: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25), heightFraction: 0.1,
                                           scales: [0.9, 1.1], grayscale: "red-emphasis")
        #expect(options.searchRegion == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
        #expect(options.templateHeightFraction == 0.1)
        #expect(options.scaleVariations == [0.9, 1.1])
        #expect(options.grayscale == .redEmphasis)
        #expect(TemplateMatchOptions(regionSearch: nil, heightFraction: nil, scales: nil, grayscale: "luminance").grayscale == .luminance)
    }
}

/// `matches` stops at a match that is mostly over an earlier one: what's
/// left of the first around the paint isn't a second copy (a region needle
/// read as ambiguous before, 0.53 beside a 1.00). `overlap` is that measure.
@Suite("Matches over an earlier one")
struct MatchOverlapTests {
    private let first = CGRect(x: 100, y: 100, width: 40, height: 20)

    @Test("The share of the new match the earlier one covers")
    func share() {
        #expect(TemplateMatcher.overlap(first, first) == 1)
        #expect(TemplateMatcher.overlap(first, first.offsetBy(dx: 20, dy: 0)) == 0.5)
        #expect(TemplateMatcher.overlap(first, first.offsetBy(dx: 20, dy: 10)) == 0.25)
        #expect(TemplateMatcher.overlap(first, first.offsetBy(dx: 40, dy: 0)) == 0)
        #expect(TemplateMatcher.overlap(first, CGRect(x: 0, y: 0, width: 10, height: 10)) == 0)
    }

    @Test("It's measured on the new match: a small one inside a big one is all covered")
    func measuredOnTheNewOne() {
        let small = CGRect(x: 110, y: 105, width: 10, height: 5)
        #expect(TemplateMatcher.overlap(first, small) == 1)
        #expect(TemplateMatcher.overlap(small, first) == 0.0625)
        #expect(TemplateMatcher.overlap(first, .zero) == 0)
    }

    @Test("More than a quarter covered is the same place; a quarter is a second copy")
    func threshold() {
        #expect(TemplateMatcher.overlap(first, first.offsetBy(dx: 19, dy: 9)) > 0.25)
        #expect(!(TemplateMatcher.overlap(first, first.offsetBy(dx: 20, dy: 10)) > 0.25))
    }
}
