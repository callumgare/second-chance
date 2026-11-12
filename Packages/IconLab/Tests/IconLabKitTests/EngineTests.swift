import CoreGraphics
import Foundation
import Testing
@testable import IconLabKit

@Suite struct DocumentTests {
    @Test func documentRoundTripsShapesEffectsAndMasks() throws {
        let layer = Layer(name: "Subject", role: "subject",
                          content: .image(ImageContent(asset: "a", cutout: true, effects: [Effect("halftone", ["ink": "#112233", "cell": 0.025, "angle": 15])])),
                          transform: Transform(x: 0.4, y: 0.6, width: 0.8, rotation: 10),
                          mask: Mask("ring", ["outer": 0.43, "inner": 0.07]))
        let shape = Layer(name: "Bands", content: .shape(Shape("bands", ["colors": ["#ff0000", "#00ff00"]])))
        let doc = Doc(name: "Test", program: "p", fill: Fill(kind: .gradient, color: RGB(10, 20, 30)), groups: [Group(name: "G", layers: [layer, shape])])
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(Doc.self, from: data)
        #expect(back.groups[0].layers[0] == layer)
        #expect(back.groups[0].layers[1] == shape)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(obj["groups"] as? [[String: Any]])
        let l0 = try #require((groups[0]["layers"] as? [[String: Any]])?.first)
        let content = try #require(l0["content"] as? [String: Any])
        #expect(content["kind"] as? String == "image")
        #expect((content["effects"] as? [[String: Any]])?.first?["op"] as? String == "halftone")
        #expect((l0["mask"] as? [String: Any])?["kind"] as? String == "ring")
    }

    @Test func colourHexAndShade() throws {
        let c = try #require(RGB(hex: "#3c7f8f"))
        #expect(c.hex == "#3c7f8f")
        #expect(c.shade(0.5).luminance < c.luminance)
        #expect(c.shade(1.5).luminance > c.luminance)
        #expect(RGB(hex: "nope") == nil)
    }
}

@Suite struct ImagingTests {
    @Test func flatSidesFindsTheEdgesTheSubjectTouches() {
        var m = Bitmap(width: 100, height: 100, fill: (0, 0, 0, 255))
        for y in 40..<100 { for x in 20..<80 { let i = m.index(x, y); m.pixels[i] = 255; m.pixels[i + 1] = 255; m.pixels[i + 2] = 255 } }
        #expect(Analyser.flatSides(m) == ["bottom"])
    }

    @Test func outlineGrowsTheBoxOutward() {
        var b = Bitmap(width: 50, height: 50)
        for y in 10..<40 { for x in 10..<40 { b.pixels[b.index(x, y) + 3] = 255 } }
        let r = Effects.apply(Effect("outline", ["color": "#ffffff", "width": 0.01]), to: Rendered(bitmap: b), unit: 500)
        #expect(r.bitmap.width > 50)
        #expect(r.box[0] < 0 && r.box[2] > 1)
    }

    @Test func brightnessAndContrast() {
        let grey = Bitmap(width: 2, height: 1, pixels: [64, 128, 192, 200, 10, 20, 30, 0])
        func bc(_ b: Double, _ c: Double) -> [UInt8] {
            Effects.apply(Effect("brightness-contrast", ["brightness": .number(b), "contrast": .number(c)]), to: Rendered(bitmap: grey), unit: 100).bitmap.pixels
        }
        #expect(bc(0, 0) == grey.pixels)                          // unchanged at 0, 0
        #expect(bc(1, 0) == [255, 255, 255, 200, 255, 255, 255, 0])  // all the way up is white, alpha kept
        #expect(bc(-1, 0)[0..<3].allSatisfy { $0 == 0 })
        let low = bc(0, -1), high = bc(0, 1)
        #expect(low[0] > 64 && low[2] < 192)                      // less contrast pulls towards mid-grey
        #expect(high[0] < 64 && high[2] > 192)                    // more pushes away from it
    }

    @Test func shapesRenderAtTheAskedSize() {
        for t in ["solid", "pattern", "bands", "window", "crt", "disc-rims", "text", "circle"] {
            let b = Shapes.render(Shape(t, ["color": "#ff0000", "a": "#000000", "b": "#ffffff", "colors": ["#ff0000", "#0000ff"], "text": "Z"]), size: 64)
            #expect(b.width == 64 && b.height == 64)
            #expect(b.pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }, "\(t) drew nothing")
        }
    }

    @Test func legibilityIsBounded() {
        var b = Bitmap(width: 200, height: 200)
        for y in 50..<150 { for x in 50..<150 { let i = b.index(x, y); b.pixels[i] = UInt8(x); b.pixels[i + 3] = 255 } }
        let l = Deep.legibility(b)
        #expect(l >= 0 && l <= 1)
    }

    @Test func compositeRotatesAboutTheRectCentre() {
        var canvas = Bitmap(width: 100, height: 100)
        let red = Bitmap(width: 10, height: 40, fill: (255, 0, 0, 255))
        red.composite(onto: &canvas, rect: CGRect(x: 45, y: 30, width: 10, height: 40), rotation: 90)
        // rotated a quarter turn, the bar lies across the centre horizontally
        #expect(canvas.alpha(30, 50) > 200)
        #expect(canvas.alpha(50, 32) < 50)
    }
}

@Suite struct EnvTests {
    @Test func readsKeysQuotesAndComments() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        try "# comment\nA=1\nB=\"two words\"\nC=\n".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let e = Env(file: f)
        #expect(e["A"] == "1")
        #expect(e["B"] == "two words")
        #expect(e["C"] == nil)
    }
}
