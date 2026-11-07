import CoreGraphics
import CoreImage
import Foundation

/// Which parts a picture has (docs/api.md "Parts"), and which way each should turn.
nonisolated public enum PartsFinder {
    public struct Found: Sendable {
        public var parts: [Part]
        public var masks: [String: Bitmap]       // part id → its mask (grey, the picture's size)
        public var rotation: Int                 // the picture's own turn
        public var rotationWhy: String?
    }

    public static func find(_ image: Bitmap, analysis r: Analyser.Result, kind: String, programTitle: String) -> Found {
        let fullW = Double(image.width), fullH = Double(image.height)
        var parts: [Part] = []
        var masks: [String: Bitmap] = [:]

        // The subject (Vision's foreground), unless it's nearly all or nothing of the picture.
        if let m = r.mask, r.analysis.coverage > 0.03, r.analysis.coverage < 0.95, let b = maskBox(m) {
            var p = Part(id: "subject", name: "Subject", source: "subject", box: b, hasMask: true)
            p.flatSides = r.analysis.flatSides
            parts.append(p)
            masks["subject"] = m
        }
        // Each instance, when there are several (and each is a fair size).
        for (i, m) in r.instanceMasks.enumerated() {
            guard let b = maskBox(m), b[2] * b[3] > 0.02 else { continue }
            parts.append(Part(id: "inst-\(i + 1)", name: "Subject \(i + 1)", source: "instance", box: b, hasMask: true))
            masks["inst-\(i + 1)"] = m
        }
        // The title: lines of text that match the program's name.
        let words = Set(programTitle.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        let squashedTitle = squash(programTitle)
        let titleLines = r.textLines.filter { line in isTitle(line.text, words: words, squashedTitle: squashedTitle) }
        if !titleLines.isEmpty, kind != "logo" {
            var b = titleLines.map(\.box).reduce(titleLines[0].box) { union($0, $1) }
            b = pad(b, 0.02)
            // named after its biggest line (the title's own wordmark, usually)
            let main = titleLines.max { $0.box[2] * $0.box[3] < $1.box[2] * $1.box[3] }?.text ?? titleLines[0].text
            var p = Part(id: "title", name: "Title “\(main.prefix(30))”", source: "text", kind: "logo", box: b)
            p.kindSet = true
            let (rot, why) = turn(for: titleLines, minScore: 2.5, ratio: 2, subject: "Its text")
            p.rotation = rot; p.rotationAuto = rot != 0 ? true : nil; p.rotationWhy = why
            parts.append(p)
        }
        // A rectangle (a box photographed at an angle, a framed picture): straightened.
        if let q = r.rectangle, ["box-front", "box-back", "manual", "art", "unknown", "other", "screenshot", "title-screen"].contains(kind) {
            let xs: [Double] = q.map { $0[0] }, ys: [Double] = q.map { $0[1] }
            let x0: Double = xs.min() ?? 0, x1: Double = xs.max() ?? 1, y0: Double = ys.min() ?? 0, y1: Double = ys.max() ?? 1
            let b: [Double] = [x0, y0, x1 - x0, y1 - y0]
            if b[2] * b[3] < 0.93 {
                var p = Part(id: "rect", name: kind.hasPrefix("box") ? "Box (straightened)" : "Picture in a frame", source: "rectangle", box: b)
                p.quad = q
                parts.append(p)
            }
        }
        // A disc: its circle.
        if let c = r.analysis.circle, c.count == 3, kind == "disc" || (r.analysis.scores["disc"] ?? 0) > 0.7 {
            let rr = c[2] * min(fullW, fullH)
            let b = [(c[0] * fullW - rr) / fullW, (c[1] * fullH - rr) / fullH, 2 * rr / fullW, 2 * rr / fullH]
            var p = Part(id: "disc", name: "Disc", source: "disc", kind: "disc", box: b, hasMask: true)
            p.kindSet = true
            parts.append(p)
            masks["disc"] = Bitmap(width: image.width, height: image.height).withCircle(cx: c[0] * fullW, cy: c[1] * fullH, r: rr)
        }

        // The picture's own turn: only for a clear winner, and never for kinds that are tall or wide by nature.
        var rotation = 0
        var why: String?
        let tallByNature = ["box-spine", "banner"].contains(kind)
        if !r.textLines.isEmpty {
            let (rot, w) = turn(for: r.textLines, minScore: 8, ratio: 3, subject: "Most of its text")
            if rot != 0, tallByNature {
                why = "Left upright: a \(kind == "box-spine" ? "box spine" : "banner")’s text usually runs along it. \(w ?? "")"
            } else {
                rotation = rot
                why = w
            }
        }
        return Found(parts: parts, masks: masks, rotation: rotation, rotationWhy: why)
    }

    /// The turn (clockwise) that makes text read across, when one direction clearly wins.
    public static func turn(for lines: [Analyser.TextLine], minScore: Double, ratio: Double, subject: String) -> (Int, String?) {
        var votes: [Int: Double] = [:]
        for l in lines { votes[l.direction, default: 0] += l.weight }
        guard let best = votes.max(by: { $0.value < $1.value }) else { return (0, nil) }
        let second = votes.filter { $0.key != best.key }.map(\.value).max() ?? 0
        let names = [0: "across", 90: "top to bottom", 180: "upside down", 270: "bottom to top"]
        let scores = [0, 90, 180, 270].map { "\(names[$0] ?? "") \(String(format: "%.1f", votes[$0] ?? 0))" }.joined(separator: ", ")
        if best.key == 0 { return (0, nil) }
        if best.value < minScore { return (0, "Not turned: too little text to be sure (scores: \(scores)).") }
        if best.value >= second * ratio {
            let turnBy = (360 - best.key) % 360
            let turn = turnBy == 180 ? "180°" : turnBy == 90 ? "a quarter clockwise" : "a quarter anticlockwise"
            return (turnBy, "Turned \(turn) automatically: \(subject.lowercased()) reads \(names[best.key] ?? "") (scores: \(scores)).")
        }
        return (0, "Not turned: \(subject.lowercased()) is too close to call (scores: \(scores)).")
    }

    static func isTitle(_ text: String, words: Set<String>, squashedTitle: String) -> Bool {
        // a title word anywhere in the line, even run together ("FREDDIFISH")
        let joined: String = squash(text)
        let hit = words.filter { $0.count > 3 && joined.contains($0) }.count
            + words.filter { $0.count == 3 && Set(text.lowercased().split { !$0.isLetter }.map(String.init)).contains($0) }.count
        if !words.isEmpty {
            let share = Double(hit) / Double(words.count)
            if share >= 0.5 || hit >= 2 { return true }
            if hit > 0 && words.count <= 2 { return true }
        }
        let st: String = squash(text)
        return squashedTitle.count > 3 && st.contains(squashedTitle)
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func union(_ a: [Double], _ b: [Double]) -> [Double] {
        let x0 = min(a[0], b[0]), y0 = min(a[1], b[1]), x1 = max(a[0] + a[2], b[0] + b[2]), y1 = max(a[1] + a[3], b[1] + b[3])
        return [x0, y0, x1 - x0, y1 - y0]
    }

    static func pad(_ b: [Double], _ p: Double) -> [Double] {
        let x0 = max(0, b[0] - p), y0 = max(0, b[1] - p), x1 = min(1, b[0] + b[2] + p), y1 = min(1, b[1] + b[3] + p)
        return [x0, y0, x1 - x0, y1 - y0]
    }

    /// The box (0…1) of a grey mask's bright pixels.
    public static func maskBox(_ m: Bitmap) -> [Double]? {
        var x0 = m.width, y0 = m.height, x1 = -1, y1 = -1
        for y in stride(from: 0, to: m.height, by: 1) { for x in stride(from: 0, to: m.width, by: 1) where m.pixels[m.index(x, y)] > 127 {
            if x < x0 { x0 = x }; if x > x1 { x1 = x }; if y < y0 { y0 = y }; if y > y1 { y1 = y }
        } }
        guard x1 >= 0 else { return nil }
        let fullW = Double(m.width), fullH = Double(m.height)
        return [Double(x0) / fullW, Double(y0) / fullH, Double(x1 - x0 + 1) / fullW, Double(y1 - y0 + 1) / fullH]
    }
}

nonisolated extension Bitmap {
    /// A grey mask: white inside a circle, black outside.
    func withCircle(cx: Double, cy: Double, r: Double) -> Bitmap {
        var out = Bitmap(width: width, height: height, fill: (0, 0, 0, 255))
        for y in 0..<height { for x in 0..<width where hypot(Double(x) - cx, Double(y) - cy) <= r {
            let i = out.index(x, y); out.pixels[i] = 255; out.pixels[i + 1] = 255; out.pixels[i + 2] = 255
        } }
        return out
    }

    /// Turned clockwise by a multiple of 90°.
    public func turned(_ degrees: Int) -> Bitmap {
        let d = ((degrees % 360) + 360) % 360
        if d == 0 { return self }
        let w2 = d == 180 ? width : height, h2 = d == 180 ? height : width
        var out = Bitmap(width: w2, height: h2)
        for y in 0..<height { for x in 0..<width {
            let (nx, ny): (Int, Int)
            switch d {
            case 90: (nx, ny) = (height - 1 - y, x)
            case 180: (nx, ny) = (width - 1 - x, height - 1 - y)
            default: (nx, ny) = (y, width - 1 - x)
            }
            let s = index(x, y), t = out.index(nx, ny)
            out.pixels[t] = pixels[s]; out.pixels[t + 1] = pixels[s + 1]; out.pixels[t + 2] = pixels[s + 2]; out.pixels[t + 3] = pixels[s + 3]
        } }
        return out
    }
}

/// A mask's edges: grow or shrink, fill holes, soften.
nonisolated public enum MaskEdges {
    public static func apply(_ m: Bitmap, _ e: Edges?) -> Bitmap {
        guard let e else { return m }
        let w = m.width, h = m.height
        var a = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { a[i] = m.pixels[i * 4] > 127 ? 255 : 0 }
        if e.fillHoles { a = fillHoles(a, w: w, h: h) }
        if e.grow > 0.5 { a = Effects.dilate(a, w: w, h: h, radius: Int(e.grow.rounded())) }
        if e.grow < -0.5 {
            let inv = a.map { $0 > 0 ? UInt8(0) : UInt8(255) }
            a = Effects.dilate(inv, w: w, h: h, radius: Int((-e.grow).rounded())).map { $0 > 0 ? UInt8(0) : UInt8(255) }
        }
        // Soften inward: shrink by the radius, blur back out to the original edge, and never past it. The
        // cut-out keeps its size and place; only its edge fades.
        var hard = a
        if e.soften > 0.3 {
            let r = max(1, Int(e.soften.rounded()))
            let inv = a.map { $0 > 0 ? UInt8(0) : UInt8(255) }
            hard = Effects.dilate(inv, w: w, h: h, radius: r).map { $0 > 0 ? UInt8(0) : UInt8(255) }
        }
        var out = Bitmap(width: w, height: h, fill: (0, 0, 0, 255))
        for i in 0..<(w * h) { out.pixels[i * 4] = hard[i]; out.pixels[i * 4 + 1] = hard[i]; out.pixels[i * 4 + 2] = hard[i] }
        if e.soften > 0.3 {
            out = Effects.blur(out, radius: e.soften / 2)
            for i in 0..<(w * h) {
                let v = a[i] > 0 ? out.pixels[i * 4] : 0
                out.pixels[i * 4] = v; out.pixels[i * 4 + 1] = v; out.pixels[i * 4 + 2] = v; out.pixels[i * 4 + 3] = 255
            }
        }
        return out
    }

    /// Holes: background pixels not reachable from the border.
    static func fillHoles(_ a: [UInt8], w: Int, h: Int) -> [UInt8] {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard i >= 0, i < w * h, !outside[i], a[i] == 0 else { continue }
            outside[i] = true
            let x = i % w
            if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
            stack.append(i - w); stack.append(i + w)
        }
        return (0..<(w * h)).map { a[$0] > 0 || !outside[$0] ? 255 : 0 }
    }
}
