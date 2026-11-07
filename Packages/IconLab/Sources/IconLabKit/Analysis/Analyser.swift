import CoreImage
import CoreVideo
import Foundation
import Vision

/// What an image is: Vision's subject mask, text and saliency, plus measures of its own (busyness, colours, flat
/// sides, a disc's circle). The cheap tier; it runs on every image a program gets.
nonisolated public enum Analyser {
    public static let version = 8

    public struct Result: Sendable {
        public var analysis: MediaAnalysis
        public var mask: Bitmap?            // grey, the image's size
        public var kind: String
        public var kindConfidence: Double
        public var suitability: Double
        /// Each foreground instance's own mask (grey, the image's size), when Vision found more than one.
        public var instanceMasks: [Bitmap] = []
        /// Every line of text: what it says, its box (0…1, top-left), the way it reads (0 = across, 90 = top to
        /// bottom, 180 = upside down, 270 = bottom to top), and its weight (confidence × letters).
        public var textLines: [TextLine] = []
        /// The strongest rectangle (a box, a framed picture): TL, TR, BR, BL in 0…1, top-left origin.
        public var rectangle: [[Double]]?
    }

    public struct TextLine: Sendable {
        public var text: String
        public var box: [Double]
        public var direction: Int
        public var weight: Double
    }

    public static func analyse(_ image: Bitmap, name: String, knownKind: String? = nil, knownCircle: [Double]? = nil) -> Result {
        var a = MediaAnalysis()
        a.version = version
        var mask: Bitmap?
        var instances: [Bitmap] = [], lines: [TextLine] = [], rectangle: [[Double]]?
        if let cg = image.flattened().cgImage {
            let handler = VNImageRequestHandler(cgImage: cg)
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            let subject = VNGenerateForegroundInstanceMaskRequest()
            let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
            let rects = VNDetectRectanglesRequest()
            rects.maximumObservations = 2; rects.minimumSize = 0.3; rects.minimumConfidence = 0.6; rects.quadratureTolerance = 25
            try? handler.perform([text, subject, saliency, rects])
            var covered = 0.0
            for o in text.results ?? [] where o.confidence > 0.3 {
                covered += Double(o.boundingBox.width * o.boundingBox.height)
                if let s = o.topCandidates(1).first?.string {
                    a.text.append(s)
                    let dx = Double(o.topRight.x - o.topLeft.x) * Double(image.width), dy = Double(o.topRight.y - o.topLeft.y) * Double(image.height)
                    // Vision's y is up: text running down the picture has dy < 0. Clockwise degrees, top-left frame:
                    let ang = (atan2(-dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                    let dir = (Int((ang + 45).truncatingRemainder(dividingBy: 360)) / 90) * 90
                    let bb = o.boundingBox
                    lines.append(TextLine(text: s, box: [Double(bb.minX), Double(1 - bb.maxY), Double(bb.width), Double(bb.height)],
                                          direction: dir, weight: Double(o.confidence) * Double(s.filter(\.isLetter).count)))
                }
            }
            if let q = rects.results?.first {
                rectangle = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft].map { [Double($0.x), Double(1 - $0.y)] }
            }
            a.textFraction = min(covered, 1)
            if let r = subject.results?.first, !r.allInstances.isEmpty,
               let buf = try? r.generateScaledMaskForImage(forInstances: r.allInstances, from: handler) {
                mask = Analyser.bitmap(fromMask: buf, width: image.width, height: image.height)
                a.subject = true
                if r.allInstances.count > 1 {
                    for i in r.allInstances.sorted() {
                        if let b = try? r.generateScaledMaskForImage(forInstances: [i], from: handler),
                           let m = Analyser.bitmap(fromMask: b, width: image.width, height: image.height) { instances.append(m) }
                    }
                }
            }
        }
        // An image's own transparency is a mask too (an icon, a cut-out logo).
        if mask == nil, image.pixels.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element < 200 }) {
            mask = image.alphaAsMask
            a.subject = true
        }
        measure(image, mask: mask, into: &a)
        if let knownCircle { a.circle = knownCircle } else if a.circle == nil { a.circle = Disc.find(image) }
        a.pixelArt = PixelArt.detect(image)
        a.hasAlpha = Analyser.hasAlpha(image)
        let (kind, conf) = guessKind(name: name, a: a, width: image.width, height: image.height)
        let finalKind = knownKind ?? kind
        a.scores = scores(a)
        return Result(analysis: a, mask: mask, kind: finalKind, kindConfidence: knownKind == nil ? conf : 1,
                      suitability: suitability(a, kind: finalKind, width: image.width, height: image.height),
                      instanceMasks: instances, textLines: lines, rectangle: rectangle)
    }

    /// Any pixel that isn't (nearly) opaque.
    public static func hasAlpha(_ b: Bitmap) -> Bool {
        stride(from: 3, to: b.pixels.count, by: 4).contains { b.pixels[$0] < 250 }
    }

    static func bitmap(fromMask buf: CVPixelBuffer, width: Int, height: Int) -> Bitmap? {
        let ci = CIImage(cvPixelBuffer: buf)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent), var b = Bitmap(cgImage: cg) else { return nil }
        if b.width != width || b.height != height { b = b.resized(width: width, height: height) }
        // Vision's mask is in the red channel (L8 → grey); make it an opaque grey mask.
        for i in stride(from: 0, to: b.pixels.count, by: 4) {
            let v = b.pixels[i]
            b.pixels[i + 1] = v; b.pixels[i + 2] = v; b.pixels[i + 3] = 255
        }
        return b
    }

    /// Busyness, colours, entropy, the subject's coverage and solidity, and its flat sides.
    static func measure(_ image: Bitmap, mask: Bitmap?, into a: inout MediaAnalysis) {
        let w = 256, h = max(1, 256 * image.height / max(1, image.width))
        let small = image.flattened().resized(width: w, height: h)
        var grey = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { grey[y * w + x] = small.luma(small.index(x, y)) } }
        var edges = 0
        for y in 1..<max(2, h - 1) where y < h - 1 {
            for x in 1..<(w - 1) {
                let gx = grey[y * w + x + 1] - grey[y * w + x - 1]
                let gy = grey[(y + 1) * w + x] - grey[(y - 1) * w + x]
                if hypot(gx, gy) > 60 { edges += 1 }
            }
        }
        let edgeDensity = Double(edges) / Double(max(1, (w - 2) * (h - 2)))
        var hist = [Double](repeating: 0, count: 256)
        for g in grey { hist[min(255, Int(g))] += 1 }
        var entropy = 0.0
        for c in hist where c > 0 { let p = c / Double(grey.count); entropy -= p * log2(p) }
        a.entropy = entropy / 8
        var rgs: [Double] = [], ybs: [Double] = [], coarse = Set<Int>()
        for i in stride(from: 0, to: small.pixels.count, by: 4) {
            let r = Double(small.pixels[i]), g = Double(small.pixels[i + 1]), b = Double(small.pixels[i + 2])
            rgs.append(r - g); ybs.append((r + g) / 2 - b)
            coarse.insert(Int(small.pixels[i]) / 32 * 64 + Int(small.pixels[i + 1]) / 32 * 8 + Int(small.pixels[i + 2]) / 32)
        }
        func std(_ v: [Double]) -> (Double, Double) {
            let m = v.reduce(0, +) / Double(max(1, v.count))
            return (sqrt(v.reduce(0) { $0 + pow($1 - m, 2) } / Double(max(1, v.count))), m)
        }
        let (srg, mrg) = std(rgs), (syb, myb) = std(ybs)
        a.colourfulness = (hypot(srg, syb) + 0.3 * hypot(mrg, myb)) / 110
        a.colours = coarse.count
        a.busyness = min(1, edgeDensity * 5 * 0.7 + a.entropy * 0.3)
        a.palette = Palette.clusters(image, k: 6).map(\.colour.hex)
        guard let mask else { return }
        let m = mask.resized(width: 256, height: 256)
        var on = 0, x0 = 256, y0 = 256, x1 = -1, y1 = -1
        for y in 0..<256 { for x in 0..<256 where m.pixels[m.index(x, y)] > 127 {
            on += 1; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        a.coverage = Double(on) / 65536
        if x1 >= 0 {
            a.solidity = Double(on) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
            a.subjectBox = [Double(x0) / 256, Double(y0) / 256, Double(x1 - x0 + 1) / 256, Double(y1 - y0 + 1) / 256]
        }
        a.flatSides = flatSides(mask)
    }

    /// The sides of the subject that the picture's own edge cut straight: the mask reaches that edge of the image
    /// along most of the subject's span there.
    public static func flatSides(_ mask: Bitmap) -> [String] {
        let w = mask.width, h = mask.height
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where mask.pixels[mask.index(x, y)] > 127 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= 0 else { return [] }
        let band = 3
        func run(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>, alongX: Bool) -> Double {
            var hit = 0, span = 0
            if alongX {
                for x in xs { span += 1; if ys.contains(where: { mask.pixels[mask.index(x, $0)] > 127 }) { hit += 1 } }
            } else {
                for y in ys { span += 1; if xs.contains(where: { mask.pixels[mask.index($0, y)] > 127 }) { hit += 1 } }
            }
            return span > 0 ? Double(hit) / Double(span) : 0
        }
        var sides: [String] = []
        if x0 <= band, run(0...min(band, w - 1), y0...y1, alongX: false) > 0.5 { sides.append("left") }
        if x1 >= w - 1 - band, run(max(0, w - 1 - band)...(w - 1), y0...y1, alongX: false) > 0.5 { sides.append("right") }
        if y0 <= band, run(x0...x1, 0...min(band, h - 1), alongX: true) > 0.5 { sides.append("top") }
        if y1 >= h - 1 - band, run(x0...x1, max(0, h - 1 - band)...(h - 1), alongX: true) > 0.5 { sides.append("bottom") }
        return sides
    }

    static func guessKind(name: String, a: MediaAnalysis, width: Int, height: Int) -> (String, Double) {
        let n = name.lowercased()
        let words: [(String, [String])] = [
            ("disc", ["disc", "disk", "cd_", "-cd", "cd-", "label", "media"]), ("icon", [".ico", "icon", "icl8", "icn#"]),
            ("logo", ["logo", "clear-logo", "clearlogo"]), ("title-screen", ["title", "opening", "splash"]),
            ("screenshot", ["screenshot", "screen", "shot"]), ("box-back", ["back"]), ("box-spine", ["spine"]),
            ("manual", ["manual"]), ("banner", ["banner", "hero", "grid"]), ("box-front", ["cover", "front", "box"]),
        ]
        for (kind, ws) in words where ws.contains(where: n.contains) { return (kind, 0.7) }
        if let c = a.circle, c.count == 3, c[2] > 0.38 { return ("disc", 0.6) }
        // Classic screen sizes are screenshots (or title screens, which the text would tell).
        if [(640, 480), (320, 200), (320, 240), (800, 600), (1024, 768), (640, 400), (512, 342), (512, 384)].contains(where: { $0 == (width, height) }) {
            return (a.textFraction > 0.04 ? "title-screen" : "screenshot", 0.5)
        }
        if max(width, height) <= 256, abs(width - height) <= 2 { return ("icon", 0.5) }
        if a.textFraction > 0.15, a.colours < 12 { return ("logo", 0.5) }
        return ("art", 0.3)
    }

    static func scores(_ a: MediaAnalysis) -> [String: Double] {
        let text = a.textFraction, cov = a.coverage, sol = a.solidity
        var s: [String: Double] = [:]
        s["silhouette"] = (a.subject ? 1 : 0.25) * max(0, 1 - abs(cov - 0.35) * 1.6) * (1.2 - sol * 0.6) * (1 - min(text * 3, 0.7))
        s["fill"] = min(1, a.busyness * 1.4) * (0.4 + a.entropy * 0.6) * (1 - min(text * 4, 0.9)) * (a.subject ? 1 - cov * 0.6 : 1)
            * (0.6 + min(a.colourfulness, 1) * 0.4)
        s["disc"] = a.circle.map { min(1, $0[2] / 0.46) } ?? 0
        s["logo"] = min(1, text * 4) * (a.colours < 12 ? 1 : 0.5)
        s["scene"] = (a.subject ? 1 - cov : 1) * a.entropy * (1 - min(text * 3, 0.8))
        return s.mapValues { ($0 * 1000).rounded() / 1000 }
    }

    /// 0…5: how likely the image is to help make an icon.
    public static func suitability(_ a: MediaAnalysis, kind: String, width: Int, height: Int) -> Double {
        let aspect = Double(max(width, height)) / Double(max(1, min(width, height)))
        if aspect > 4 { return 0 }
        var s = 2.0
        s += ["box-front": 1.2, "logo": 1.2, "disc": 1, "icon": 1, "title-screen": 0.8, "banner": 0.5, "cutout": 1,
              "screenshot": -0.3, "box-back": -1, "box-spine": -1, "manual": -1.2][kind] ?? 0
        // Resolution counts all the way up: each doubling of the shorter side is worth about a third of a point
        // (128 px ±0, 256 +0.35, 512 +0.7, 1024 +1.05, capped at +1.2). A program's own icon is small by nature,
        // so it isn't marked down for it.
        let side = Double(max(1, min(width, height)))
        let sizeTerm = max(-1, min(1.2, (log2(side) - 7) * 0.35))
        s += kind == "icon" || a.pixelArt == true ? max(0, sizeTerm) : sizeTerm
        if a.subject { s += 0.5 }
        if aspect > 2 { s -= 0.8 }
        if a.busyness > 0.75 { s -= 0.4 }
        return max(0, min(5, (s * 10).rounded() / 10))
    }
}

/// A disc's circle: a near-square picture, one big circle in it (the outer edge), found by fitting a circle to the
/// image's strongest radial edge. Cheap stand-in for a Hough transform.
nonisolated public enum Disc {
    public static func find(_ image: Bitmap) -> [Double]? {
        let aspect = Double(image.width) / Double(max(1, image.height))
        guard aspect > 0.8, aspect < 1.25 else { return nil }
        let n = 128
        let small = image.flattened().resized(width: n, height: n)
        func g(_ x: Int, _ y: Int) -> Double { small.luma(small.index(max(0, min(n - 1, x)), max(0, min(n - 1, y)))) }
        // For each of 32 directions from the centre, the radius with the biggest brightness step.
        var radii: [Double] = []
        for k in 0..<32 {
            let th = Double(k) / 32 * 2 * .pi
            var best = 0.0, bestR = 0.0
            for r in stride(from: Double(n) * 0.3, to: Double(n) * 0.5, by: 1) {
                let x = Double(n) / 2 + cos(th) * r, y = Double(n) / 2 + sin(th) * r
                let x2 = Double(n) / 2 + cos(th) * (r + 2), y2 = Double(n) / 2 + sin(th) * (r + 2)
                let step = abs(g(Int(x), Int(y)) - g(Int(x2), Int(y2)))
                if step > best { best = step; bestR = r + 1 }
            }
            if best > 25 { radii.append(bestR) }
        }
        guard radii.count >= 24 else { return nil }
        let mean = radii.reduce(0, +) / Double(radii.count)
        let sd = sqrt(radii.reduce(0) { $0 + pow($1 - mean, 2) } / Double(radii.count))
        guard sd < Double(n) * 0.03 else { return nil }
        // The hub: the centre differs from the label around it.
        return [0.5, 0.5, mean / Double(n)]
    }
}

/// Pixel art: few colours, hard edges on a grid (the program's own icon, a sprite).
nonisolated public enum PixelArt {
    public static func detect(_ image: Bitmap) -> Bool {
        if max(image.width, image.height) <= 64 { return true }
        var colours = Set<UInt32>()
        let step = max(1, image.pixels.count / 4 / 20000)
        for i in stride(from: 0, to: image.pixels.count, by: 4 * step) {
            colours.insert(UInt32(image.pixels[i]) << 16 | UInt32(image.pixels[i + 1]) << 8 | UInt32(image.pixels[i + 2]))
            if colours.count > 256 { return false }
        }
        return max(image.width, image.height) <= 320
    }
}
