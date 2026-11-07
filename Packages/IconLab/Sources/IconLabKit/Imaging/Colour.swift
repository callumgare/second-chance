import CoreGraphics
import Foundation

nonisolated public struct RGB: Sendable, Hashable, Codable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(r: Double, g: Double, b: Double) {
        func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        self.init(c(r), c(g), c(b))
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255))
    }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGB(hex: s) else { throw IconLabError.invalid("colour \(s)") }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Icon Composer's colour notation.
    public var iconComposer: String {
        String(format: "srgb:%.5f,%.5f,%.5f,1.00000", Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    // MARK: HLS (as Python's colorsys, which the first lab used)

    public var hls: (h: Double, l: Double, s: Double) {
        let r = Double(self.r) / 255, g = Double(self.g) / 255, b = Double(self.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, l, 0) }
        let d = mx - mn
        let s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
        let rc = (mx - r) / d, gc = (mx - g) / d, bc = (mx - b) / d
        var h: Double
        if r == mx { h = bc - gc } else if g == mx { h = 2 + rc - bc } else { h = 4 + gc - rc }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return (h, l, s)
    }

    public static func fromHLS(_ h: Double, _ l: Double, _ s: Double) -> RGB {
        let h = h.truncatingRemainder(dividingBy: 1) + (h < 0 ? 1 : 0)
        let l = max(0, min(1, l)), s = max(0, min(1, s))
        if s == 0 { return RGB(r: l * 255, g: l * 255, b: l * 255) }
        let m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s
        let m1 = 2 * l - m2
        func v(_ hue: Double) -> Double {
            let hue = hue.truncatingRemainder(dividingBy: 1) + (hue < 0 ? 1 : 0)
            if hue < 1.0 / 6 { return m1 + (m2 - m1) * hue * 6 }
            if hue < 0.5 { return m2 }
            if hue < 2.0 / 3 { return m1 + (m2 - m1) * (2.0 / 3 - hue) * 6 }
            return m1
        }
        return RGB(r: v(h + 1.0 / 3) * 255, g: v(h) * 255, b: v(h - 1.0 / 3) * 255)
    }

    /// Lighter (f > 1) or darker (f < 1), keeping the hue.
    public func shade(_ f: Double) -> RGB {
        let (h, l, s) = hls
        return RGB.fromHLS(h, f < 1 ? l * f : l + (1 - l) * (f - 1), s)
    }

    public func mix(_ other: RGB, _ t: Double) -> RGB {
        let rr: Double = Double(r) * (1 - t) + Double(other.r) * t
        let gg: Double = Double(g) * (1 - t) + Double(other.g) * t
        let bb: Double = Double(b) * (1 - t) + Double(other.b) * t
        return RGB(r: rr, g: gg, b: bb)
    }

    public var luminance: Double { (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255 }

    // MARK: Lab

    public var lab: (l: Double, a: Double, b: Double) {
        func lin(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(self.r), g = lin(self.g), b = lin(self.b)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    public var chroma: Double { let l = lab; return hypot(l.a, l.b) }
}

nonisolated public enum Palette {
    /// The image's colours: k-means in Lab over a small copy, most common first, with each one's share.
    public static func clusters(_ image: Bitmap, k: Int = 8) -> [(colour: RGB, share: Double)] {
        let small = image.resized(width: 96, height: max(1, 96 * image.height / max(1, image.width)))
        var points: [(Double, Double, Double, RGB)] = []
        for i in stride(from: 0, to: small.pixels.count, by: 4) where small.pixels[i + 3] > 128 {
            let c = RGB(small.pixels[i], small.pixels[i + 1], small.pixels[i + 2])
            let l = c.lab
            points.append((l.l, l.a, l.b, c))
        }
        guard !points.isEmpty else { return [] }
        let k = min(k, points.count)
        // k-means++ style seeding, deterministic: the first point, then each farthest from the chosen.
        var centres = [(points[0].0, points[0].1, points[0].2)]
        while centres.count < k {
            var far = 0, farD = -1.0
            for (i, p) in points.enumerated() {
                let d = centres.map { pow(p.0 - $0.0, 2) + pow(p.1 - $0.1, 2) + pow(p.2 - $0.2, 2) }.min() ?? 0
                if d > farD { farD = d; far = i }
            }
            centres.append((points[far].0, points[far].1, points[far].2))
        }
        var labels = [Int](repeating: 0, count: points.count)
        for _ in 0..<12 {
            for (i, p) in points.enumerated() {
                var best = 0, bestD = Double.infinity
                for (j, c) in centres.enumerated() {
                    let d = pow(p.0 - c.0, 2) + pow(p.1 - c.1, 2) + pow(p.2 - c.2, 2)
                    if d < bestD { bestD = d; best = j }
                }
                labels[i] = best
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
            for (i, p) in points.enumerated() {
                let j = labels[i]
                sums[j].0 += p.0; sums[j].1 += p.1; sums[j].2 += p.2; sums[j].3 += 1
            }
            for j in 0..<k where sums[j].3 > 0 {
                centres[j] = (sums[j].0 / Double(sums[j].3), sums[j].1 / Double(sums[j].3), sums[j].2 / Double(sums[j].3))
            }
        }
        // Represent each cluster by the mean of its members' RGB (avoids a Lab→RGB conversion).
        var rgbSums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
        for (i, p) in points.enumerated() {
            let j = labels[i]
            rgbSums[j].0 += Double(p.3.r); rgbSums[j].1 += Double(p.3.g); rgbSums[j].2 += Double(p.3.b); rgbSums[j].3 += 1
        }
        return rgbSums.filter { $0.3 > 0 }
            .map { (RGB(r: $0.0 / Double($0.3), g: $0.1 / Double($0.3), b: $0.2 / Double($0.3)), Double($0.3) / Double(points.count)) }
            .sorted { $0.share > $1.share }
    }

    /// The colours offered for an icon's primary and secondary, named so a person can tell what each is.
    public static func options(_ image: Bitmap) -> [(name: String, colour: RGB)] {
        let cs = clusters(image)
        guard let dominant = cs.first?.colour else { return [] }
        let striking = cs.max { $0.colour.chroma * pow($0.share, 0.35) < $1.colour.chroma * pow($1.share, 0.35) }?.colour ?? dominant
        let second = cs.filter { $0.colour != striking }
            .max { $0.colour.chroma * pow($0.share, 0.35) < $1.colour.chroma * pow($1.share, 0.35) }?.colour ?? dominant
        var sum = (0.0, 0.0, 0.0), n = 0.0
        let small = image.resized(width: 64, height: 64)
        for i in stride(from: 0, to: small.pixels.count, by: 4) where small.pixels[i + 3] > 128 {
            sum.0 += Double(small.pixels[i]); sum.1 += Double(small.pixels[i + 1]); sum.2 += Double(small.pixels[i + 2]); n += 1
        }
        let average = n > 0 ? RGB(r: sum.0 / n, g: sum.1 / n, b: sum.2 / n) : dominant
        let byL = cs.sorted { $0.colour.lab.l < $1.colour.lab.l }
        let (h, l, s) = striking.hls
        return [
            ("striking", striking), ("second striking", second), ("dominant", dominant), ("average", average),
            ("complement", RGB.fromHLS(h + 0.5, l, s)), ("split complement", RGB.fromHLS(h + 0.42, l, s)),
            ("analogous", RGB.fromHLS(h + 0.08, l, s)),
            ("darkest", byL.first?.colour ?? dominant), ("lightest", byL.last?.colour ?? dominant),
            ("deep striking", RGB.fromHLS(h, min(l, 0.22), s)), ("pale striking", RGB.fromHLS(h, max(l, 0.85), s * 0.7)),
            ("black", RGB(18, 18, 20)), ("white", RGB(246, 246, 244)),
        ]
    }
}
