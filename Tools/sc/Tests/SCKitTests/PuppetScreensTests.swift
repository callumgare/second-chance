import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import Testing
import WrappBuilder
@testable import SCKit

/// Naming a puppet session's screens with needles, cutting needles from a
/// frame, and the locators `do` takes, on frames drawn here.
@Suite("Puppet screens and locators")
struct PuppetScreensTests {
    /// A frame of a window `width`x`height` points at 1 pixel a point: dark
    /// grey, with `rectangles` drawn (top-left origin) in their colours.
    private static func frame(width: Int = 320, height: Int = 240,
                              _ rectangles: [(CGRect, (Double, Double, Double))]) throws -> PuppetFrame {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (rect, (red, green, blue)) in rectangles {
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        let image = try #require(context.makeImage())
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).png")
        try PuppetFrame.write(image, to: path)
        return PuppetFrame(path: path, image: image, width: Double(width), height: Double(height))
    }

    /// A red button with a white mark, its top-left corner at (x, y).
    private static func button(_ x: Double, _ y: Double) -> [(CGRect, (Double, Double, Double))] {
        [(CGRect(x: x, y: y, width: 30, height: 16), (0.9, 0.1, 0.1)), (CGRect(x: x + 10, y: y + 5, width: 10, height: 6), (1, 1, 1))]
    }

    private static let title: [(CGRect, (Double, Double, Double))] = [
        (CGRect(x: 20, y: 20, width: 280, height: 60), (0.9, 0.7, 0.1)),
        (CGRect(x: 60, y: 120, width: 200, height: 80), (0.1, 0.4, 0.8)),
    ]

    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ cut: NeedleCut, as name: String, in folder: URL) throws -> Needle {
        let yaml = folder.appendingPathComponent(name + ".yaml")
        try cut.yaml.write(to: yaml, atomically: true, encoding: .utf8)
        if let image = cut.image { try PuppetFrame.write(image, to: folder.appendingPathComponent(name + ".png")) }
        return try NeedleLibrary.needle(at: yaml)
    }

    @Test("The commands parse; a locator is one of --text or --needle, and --nth counts from 1")
    func parsing() throws {
        let screen = try #require(try SC.parseAsRoot(["puppet", "screen", "lure", "--bundle", "freeware/skifree"]) as? PuppetScreenCommand)
        #expect(screen.source.bundle == "freeware/skifree")
        let name = try #require(try SC.parseAsRoot(["puppet", "name", "lure", "title", "--region", "10,20,30,40", "--text"]) as? PuppetNameCommand)
        #expect(name.tag == "title" && name.text && name.region == "10,20,30,40")
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["puppet", "name", "lure", "title", "--region", "10,20"]) }
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["puppet", "expect", "lure"]) }
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["puppet", "expect", "lure", "--screen", "a", "--text", "b"]) }
        let action = try #require(try SC.parseAsRoot(["puppet", "do", "lure", "click", "--text", "Save game", "--nth", "2"]) as? PuppetActionCommand)
        #expect(action.action == ["click"])
        #expect(action.locator.locateText == "Save game" && action.locator.nth == 2)
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["puppet", "do", "lure", "click", "--text", "a", "--needle", "b.yaml"]) }
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["puppet", "do", "lure", "click", "--text", "a", "--nth", "0"]) }
        #expect(throws: (any Error).self) { try SC.parseAsRoot(["puppet", "do", "lure", "click", "1", "2", "--nth", "1"]) }
    }

    @Test("A screen needle cut from a frame names that frame, and not another")
    func screenNeedle() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let titleFrame = try Self.frame(Self.title)
        let cut = try NeedleCut.make(tag: "title", from: titleFrame, region: nil, text: false, origin: "a test")
        #expect(cut.kind == "screen")
        let needle = try Self.write(cut, as: "title", in: folder)
        #expect(needle.spec.kind == .screen && needle.spec.tags == ["title"])

        let same = PuppetScreens.identify(titleFrame, needles: [needle])
        #expect(same.name == "title")
        let other = PuppetScreens.identify(try Self.frame([(CGRect(x: 0, y: 0, width: 160, height: 240), (0.2, 0.8, 0.3))]), needles: [needle])
        #expect(other.name == nil)
        #expect(other.nearest("title")?.detail.contains("distance") == true)
        #expect(other.report(max: 5) == ["  title: no, nearest title: \(other.results[0].detail)"])
    }

    @Test("A region needle is searched for around where it was cut, and found on a frame with it")
    func regionNeedle() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let withButton = try Self.frame(Self.title + Self.button(250, 200))
        let cut = try NeedleCut.make(tag: "quit", from: withButton, region: CGRect(x: 250, y: 200, width: 30, height: 16), text: false, origin: "a test")
        #expect(cut.kind == "region")
        #expect(cut.yaml.contains("height-fraction: 0.0667"))
        // Its own size again on each side, within the window.
        #expect(cut.yaml.contains("search: { x: 0.6875, y: 0.7667, width: 0.28"))
        #expect(cut.yaml.contains("height: 0.2 }"))
        let needle = try Self.write(cut, as: "quit", in: folder)

        let found = try #require(PuppetScreens.identify(withButton, needles: [needle]).found("quit"))
        let rect = try #require(found.rect)
        #expect(abs(rect.minX - 250) <= 1 && abs(rect.minY - 200) <= 1)
        let target = try #require(PuppetScreens.locations(of: needle, in: withButton, limit: 2).first)
        #expect(abs(target.point.x - 265) <= 1 && abs(target.point.y - 208) <= 1)
    }

    @Test("A needle cut from outside the window, or from a blank screen, is refused")
    func refusedCuts() throws {
        let frame = try Self.frame(Self.title)
        #expect(throws: SCError.self) { try NeedleCut.make(tag: "x", from: frame, region: CGRect(x: 400, y: 10, width: 20, height: 20), text: false, origin: "") }
        let blank = try Self.frame([(CGRect(x: 0, y: 0, width: 320, height: 240), (0, 0, 0))])
        #expect(throws: SCError.self) { try NeedleCut.make(tag: "x", from: blank, region: nil, text: false, origin: "") }
    }

    @Test("Strict locating: one match is it, two is an error listing both (exit 5), --nth picks in reading order")
    func strictness() throws {
        func target(_ x: Double, _ y: Double, _ name: String) -> PuppetTarget {
            PuppetTarget(rect: CGRect(x: x, y: y, width: 40, height: 10), point: CGPoint(x: x + 20, y: y + 5), description: name)
        }
        let below = target(10, 100, "below"), above = target(200, 20, "above")
        #expect(try PuppetLocator.pick([], nth: nil, what: "it") == nil)
        #expect(try PuppetLocator.pick([below], nth: nil, what: "it")?.description == "below")
        do {
            _ = try PuppetLocator.pick([below, above], nth: nil, what: "\"Load\"")
            Issue.record("two matches should be an error")
        } catch let error as SCError {
            #expect(error.exitCode == 5)
            #expect(error.message.contains("1. above") && error.message.contains("2. below"))
        }
        #expect(try PuppetLocator.pick([below, above], nth: 2, what: "it")?.description == "below")
        #expect(try PuppetLocator.pick([below], nth: 2, what: "it") == nil)
    }

    @Test("Similarity ranks the nearest line to text that wasn't found")
    func similarity() {
        #expect(Similarity.of("Save game", "save game") == 1)
        #expect(Similarity.of("Save gane", "Save game") > Similarity.of("Load game", "Save game"))
        #expect(Similarity.of("", "Save") == 0)
    }

    @Test("A needle's YAML quotes what OCR read, and rounds fractions as the bundles write them")
    func yamlText() {
        #expect(NeedleCut.quoted(#"Say "hi" \ bye"#) == #""Say \"hi\" \\ bye""#)
        #expect(NeedleCut.fraction(0.123456) == "0.1235")
        #expect(NeedleCut.fraction(1) == "1")
        #expect(NeedleCut.fraction(0) == "0")
    }
}
