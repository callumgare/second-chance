import CoreGraphics
import CoreImage
import Foundation

/// A rendered piece of content: the pixels, and where they sit relative to the content's own box ([0,0,1,1] unless
/// an effect drew outside it, as an outline does).
nonisolated public struct Rendered: Sendable {
    public var bitmap: Bitmap
    public var box: [Double] = [0, 0, 1, 1]   // x0, y0, x1, y1 in content-box units
}

/// Effects, applied in the content's own space. `unit` is pixels per canvas unit (a canvas unit = the whole icon's
/// width), so sizes in the document (canvas units) become pixels.
nonisolated public enum Effects {
    public static func apply(_ e: Effect, to r: Rendered, unit: Double) -> Rendered {
        var r = r
        let t = e.t
        switch e.op {
        case "silhouette":
            let c = t.colour("color")
            for i in stride(from: 0, to: r.bitmap.pixels.count, by: 4) {
                r.bitmap.pixels[i] = c.r; r.bitmap.pixels[i + 1] = c.g; r.bitmap.pixels[i + 2] = c.b
            }
        case "feather":
            r = feather(r, softness: max(0, t.double("softness", 0.03) * unit), offset: t.double("offset", 0) * unit)
        case "outline":
            r = outline(r, colour: t.colour("color", RGB(255, 255, 255)), width: max(1, t.double("width", 0.02) * unit))
        case "halftone":
            r.bitmap = halftone(r.bitmap, ink: t.colour("ink"), cell: max(3, t.double("cell", 26.0 / 1024) * unit),
                                angle: t.double("angle", 15))
        case "tone":
            r.bitmap = tone(r.bitmap, level: Int(t.double("level", 0)), colour: t.colour("color"))
        case "gradient-map":
            r.bitmap = gradientMap(r.bitmap, dark: t.colour("dark"), light: t.colour("light", RGB(255, 255, 255)))
        case "blur":
            r.bitmap = blur(r.bitmap, radius: t.double("radius", 4.0 / 1024) * unit)
        case "autocontrast":
            r.bitmap = autocontrast(r.bitmap)
        case "edges":
            r.bitmap = edges(r.bitmap, colour: t.colour("color", RGB(255, 255, 255)), unit: unit)
        case "riso":
            let off = t.doubles("offset")
            r.bitmap = riso(r.bitmap, ink: t.colour("ink"), mid: t.string("band") == "mid",
                            offset: (off.first ?? 0) * unit, offsetY: (off.count > 1 ? off[1] : 0) * unit)
        case "posterize":
            r.bitmap = posterize(r.bitmap, colours: max(2, Int(t.double("colors", 5))))
        case "scanlines":
            let period = max(2, Int((6.0 / 1024 * unit).rounded()))
            for y in stride(from: 0, to: r.bitmap.height, by: period) {
                for x in 0..<r.bitmap.width {
                    let i = r.bitmap.index(x, y)
                    for k in 0..<3 { r.bitmap.pixels[i + k] = UInt8(Double(r.bitmap.pixels[i + k]) * 0.72) }
                }
            }
        case "tint":
            let c = t.colour("color"), a = t.double("amount", 0.45)
            for i in stride(from: 0, to: r.bitmap.pixels.count, by: 4) {
                r.bitmap.pixels[i] = UInt8(Double(r.bitmap.pixels[i]) * (1 - a) + Double(c.r) * a)
                r.bitmap.pixels[i + 1] = UInt8(Double(r.bitmap.pixels[i + 1]) * (1 - a) + Double(c.g) * a)
                r.bitmap.pixels[i + 2] = UInt8(Double(r.bitmap.pixels[i + 2]) * (1 - a) + Double(c.b) * a)
            }
        case "key":
            r.bitmap = keyBackground(r.bitmap, tolerance: t.double("tolerance", 30))
        case "flatten":
            r.bitmap = r.bitmap.flattened(over: t.colour("color", RGB(255, 255, 255)))
        default:
            break
        }
        return r
    }

    // MARK: -

    static func outline(_ r: Rendered, colour: RGB, width: Double) -> Rendered {
        let pad = Int(width.rounded(.up)) + 2
        let b = r.bitmap
        let w = b.width + pad * 2, h = b.height + pad * 2
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<b.height { for x in 0..<b.width { alpha[(y + pad) * w + x + pad] = b.alpha(x, y) > 100 ? 255 : 0 } }
        let grown = dilate(alpha, w: w, h: h, radius: Int(width.rounded()))
        var out = Bitmap(width: w, height: h)
        for i in 0..<(w * h) where grown[i] > 0 {
            out.pixels[i * 4] = colour.r; out.pixels[i * 4 + 1] = colour.g; out.pixels[i * 4 + 2] = colour.b; out.pixels[i * 4 + 3] = 255
        }
        b.composite(onto: &out, rect: CGRect(x: pad, y: pad, width: b.width, height: b.height))
        let fx = Double(pad) / Double(b.width), fy = Double(pad) / Double(b.height)
        return Rendered(bitmap: out, box: [r.box[0] - fx * (r.box[2] - r.box[0]), r.box[1] - fy * (r.box[3] - r.box[1]),
                                           r.box[2] + fx * (r.box[2] - r.box[0]), r.box[3] + fy * (r.box[3] - r.box[1])])
    }

    /// Feathers the edge: alpha fades from opaque to clear across `softness` pixels, centred on the edge moved by
    /// `offset` pixels (negative: in; positive: out, the colours carried out from the nearest edge). Holes feather too.
    /// `backing`: for a cut-out, the picture it was cut from, at the content's scale, `backingPad` pixels bigger on
    /// every side than the content: where the edge moves out, it shows that picture rather than carrying colours out.
    static func feather(_ r: Rendered, softness: Double, offset: Double, backing: Bitmap? = nil, backingPad: Double = 0) -> Rendered {
        let b = r.bitmap
        let reach = max(0, offset + softness / 2)
        let pad = Int(reach.rounded(.up)) + (reach > 0 ? 2 : 0)
        let w = b.width + pad * 2, h = b.height + pad * 2
        var src = Bitmap(width: w, height: h)
        b.composite(onto: &src, rect: CGRect(x: pad, y: pad, width: b.width, height: b.height))
        var solid = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { solid[i] = src.pixels[i * 4 + 3] > 127 }
        let toInside = distance(solid, w: w, h: h)                // for outside pixels: how far to the shape
        let toOutside = distance(solid.map { !$0 }, w: w, h: h)  // for inside pixels: how far to the edge
        // colours for the pixels the edge moves out over: each outside pixel takes the colour bled from the shape
        var bled = src
        if offset + softness / 2 > 0.5 {
            // Core Image blurs premultiplied and hands back straight colours: an alpha-weighted average of the shape's
            let bl = blurAll(src, sigma: max(2, reach / 2))
            for i in 0..<(w * h) where !solid[i] && bl.pixels[i * 4 + 3] > 0 {
                for k in 0..<3 { bled.pixels[i * 4 + k] = bl.pixels[i * 4 + k] }
            }
        }
        if let bk = backing {
            // the uncut picture around the cut-out, where it has one (outside the picture, the carried colours stay)
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                guard !solid[i] || src.pixels[i * 4 + 3] < 255 else { continue }
                let bx = Int((Double(x - pad) + backingPad).rounded()), by = Int((Double(y - pad) + backingPad).rounded())
                guard bx >= 0, by >= 0, bx < bk.width, by < bk.height else { continue }
                let j = bk.index(bx, by)
                guard bk.pixels[j + 3] > 0 else { continue }
                bled.pixels[i * 4] = bk.pixels[j]; bled.pixels[i * 4 + 1] = bk.pixels[j + 1]; bled.pixels[i * 4 + 2] = bk.pixels[j + 2]
                bled.pixels[i * 4 + 3] = bk.pixels[j + 3]
            } }
        }
        var out = Bitmap(width: w, height: h)
        let s = max(0.5, softness)
        for i in 0..<(w * h) {
            // signed distance from the edge (+ inside), in pixels, the edge sitting between pixels
            let d = solid[i] ? Double(toOutside[i]) - 0.5 : -(Double(toInside[i]) - 0.5)
            let f = max(0, min(1, (d + offset) / s + 0.5))
            guard f > 0 else { continue }
            if solid[i], backing != nil, src.pixels[i * 4 + 3] < 255 {
                // a cut-out's soft edge, laid over the picture it came from, so nothing shows through between them
                let sa = Double(src.pixels[i * 4 + 3]) / 255, ba = Double(bled.pixels[i * 4 + 3]) / 255
                let oa = sa + ba * (1 - sa)
                for k in 0..<3 {
                    let v = (Double(src.pixels[i * 4 + k]) * sa + Double(bled.pixels[i * 4 + k]) * ba * (1 - sa)) / max(0.001, oa)
                    out.pixels[i * 4 + k] = UInt8(max(0, min(255, v.rounded())))
                }
                out.pixels[i * 4 + 3] = UInt8((oa * f * 255).rounded())
                continue
            }
            let a = solid[i] ? Double(src.pixels[i * 4 + 3]) / 255 * f : f * (backing != nil ? Double(bled.pixels[i * 4 + 3]) / 255 : 1)
            let c = solid[i] ? src : bled
            out.pixels[i * 4] = c.pixels[i * 4]; out.pixels[i * 4 + 1] = c.pixels[i * 4 + 1]; out.pixels[i * 4 + 2] = c.pixels[i * 4 + 2]
            out.pixels[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        guard pad > 0 else { return Rendered(bitmap: out, box: r.box) }
        let fx = Double(pad) / Double(b.width), fy = Double(pad) / Double(b.height)
        return Rendered(bitmap: out, box: [r.box[0] - fx * (r.box[2] - r.box[0]), r.box[1] - fy * (r.box[3] - r.box[1]),
                                           r.box[2] + fx * (r.box[2] - r.box[0]), r.box[3] + fy * (r.box[3] - r.box[1])])
    }

    /// Each pixel's distance (in pixels, chamfer 5-7) to the nearest `true` one.
    static func distance(_ a: [Bool], w: Int, h: Int) -> [Float] {
        var d = [Int](repeating: Int.max / 4, count: w * h)
        for i in 0..<(w * h) where a[i] { d[i] = 0 }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            if x > 0 { d[i] = min(d[i], d[i - 1] + 5) }
            if y > 0 { d[i] = min(d[i], d[i - w] + 5) }
            if x > 0, y > 0 { d[i] = min(d[i], d[i - w - 1] + 7) }
            if x < w - 1, y > 0 { d[i] = min(d[i], d[i - w + 1] + 7) }
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            let i = y * w + x
            if x < w - 1 { d[i] = min(d[i], d[i + 1] + 5) }
            if y < h - 1 { d[i] = min(d[i], d[i + w] + 5) }
            if x < w - 1, y < h - 1 { d[i] = min(d[i], d[i + w + 1] + 7) }
            if x > 0, y < h - 1 { d[i] = min(d[i], d[i + w - 1] + 7) }
        } }
        return d.map { Float($0) / 5 }
    }

    /// A Gaussian blur of every channel, alpha too (`blur` keeps the alpha).
    static func blurAll(_ b: Bitmap, sigma: Double) -> Bitmap {
        guard let cg = b.cgImage else { return b }
        let ci = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: sigma)
            .cropped(to: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        guard let out = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: b.width, height: b.height)),
              let res = Bitmap(cgImage: out) else { return b }
        return res
    }

    /// A disc-shaped dilation (two separable passes of a square, then a circle check would be exact; the square
    /// pass is close enough for a sticker border and much faster).
    static func dilate(_ a: [UInt8], w: Int, h: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return a }
        // Distance transform (chamfer) then threshold: round corners, linear time.
        var d = [Int](repeating: Int.max / 4, count: w * h)
        for i in 0..<(w * h) where a[i] > 0 { d[i] = 0 }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            if x > 0 { d[i] = min(d[i], d[i - 1] + 5) }
            if y > 0 { d[i] = min(d[i], d[i - w] + 5) }
            if x > 0, y > 0 { d[i] = min(d[i], d[i - w - 1] + 7) }
            if x < w - 1, y > 0 { d[i] = min(d[i], d[i - w + 1] + 7) }
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            let i = y * w + x
            if x < w - 1 { d[i] = min(d[i], d[i + 1] + 5) }
            if y < h - 1 { d[i] = min(d[i], d[i + w] + 5) }
            if x < w - 1, y < h - 1 { d[i] = min(d[i], d[i + w + 1] + 7) }
            if x > 0, y < h - 1 { d[i] = min(d[i], d[i + w - 1] + 7) }
        } }
        return d.map { $0 <= radius * 5 ? 255 : 0 }
    }

    static func halftone(_ b: Bitmap, ink: RGB, cell: Double, angle: Double) -> Bitmap {
        let flat = b.flattened()
        let th = angle * .pi / 180
        let cx = Double(b.width) / 2, cy = Double(b.height) / 2
        let reach = hypot(Double(b.width), Double(b.height)) / 2 + cell
        return Bitmap.draw(width: b.width, height: b.height) { ctx in
            ctx.setFillColor(ink.cgColor)
            var v = -reach
            while v <= reach {
                var u = -reach
                while u <= reach {
                    // grid point in the rotated frame → image coordinates
                    let x = cx + u * cos(th) - v * sin(th), y = cy + u * sin(th) + v * cos(th)
                    u += cell
                    guard x >= 0, y >= 0, x < Double(b.width), y < Double(b.height) else { continue }
                    // average over the cell (a few samples)
                    var sum = 0.0, alpha = 0.0, n = 0.0
                    for oy in [-0.3, 0, 0.3] { for ox in [-0.3, 0, 0.3] {
                        let sx = Int(max(0, min(Double(b.width - 1), x + ox * cell)))
                        let sy = Int(max(0, min(Double(b.height - 1), y + oy * cell)))
                        sum += flat.luma(flat.index(sx, sy)); alpha += Double(b.alpha(sx, sy)); n += 1
                    } }
                    if alpha / n < 100 { continue }
                    let r = pow(1 - sum / n / 255, 0.8) * cell * 0.62
                    if r > 0.5 { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
                }
                v += cell
            }
        }
    }

    static func tone(_ b: Bitmap, level: Int, colour: RGB) -> Bitmap {
        var lumas: [Double] = []
        for i in stride(from: 0, to: b.pixels.count, by: 4) where b.pixels[i + 3] > 0 { lumas.append(b.luma(i)) }
        lumas.sort()
        let q1 = lumas.isEmpty ? 85 : lumas[lumas.count / 3], q2 = lumas.isEmpty ? 170 : lumas[lumas.count * 2 / 3]
        var out = Bitmap(width: b.width, height: b.height)
        for i in stride(from: 0, to: b.pixels.count, by: 4) where b.pixels[i + 3] > 127 {
            let l = b.luma(i)
            let idx = l < q1 ? 0 : (l < q2 ? 1 : 2)
            if idx >= level {
                out.pixels[i] = colour.r; out.pixels[i + 1] = colour.g; out.pixels[i + 2] = colour.b; out.pixels[i + 3] = 255
            }
        }
        return out
    }

    static func gradientMap(_ b: Bitmap, dark: RGB, light: RGB) -> Bitmap {
        var lumas: [Double] = []
        for i in stride(from: 0, to: b.pixels.count, by: 4) { lumas.append(b.luma(i)) }
        let sorted = lumas.sorted()
        let lo = sorted.isEmpty ? 0 : sorted[sorted.count / 100], hi = sorted.isEmpty ? 255 : sorted[sorted.count * 99 / 100]
        var out = b
        for (k, l) in lumas.enumerated() {
            let t = max(0, min(1, (l - lo) / max(1, hi - lo)))
            let c = dark.mix(light, t)
            out.pixels[k * 4] = c.r; out.pixels[k * 4 + 1] = c.g; out.pixels[k * 4 + 2] = c.b
        }
        return out
    }

    static func blur(_ b: Bitmap, radius: Double) -> Bitmap {
        guard radius > 0.3, let cg = b.cgImage else { return b }
        let ci = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: radius)
            .cropped(to: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        guard let out = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: b.width, height: b.height)),
              var res = Bitmap(cgImage: out) else { return b }
        // keep the original alpha edge (blur colours, not the cut-out's outline)
        for i in stride(from: 3, to: res.pixels.count, by: 4) { res.pixels[i] = b.pixels[i] }
        return res
    }

    static func autocontrast(_ b: Bitmap) -> Bitmap {
        var out = b
        for k in 0..<3 {
            var vals: [UInt8] = []
            for i in stride(from: k, to: b.pixels.count, by: 4) { vals.append(b.pixels[i]) }
            vals.sort()
            guard !vals.isEmpty else { continue }
            let lo = Double(vals[vals.count / 50]), hi = Double(vals[vals.count * 49 / 50])
            guard hi > lo else { continue }
            for i in stride(from: k, to: b.pixels.count, by: 4) {
                out.pixels[i] = UInt8(max(0, min(255, (Double(b.pixels[i]) - lo) / (hi - lo) * 255)))
            }
        }
        return out
    }

    static func edges(_ b: Bitmap, colour: RGB, unit: Double) -> Bitmap {
        let w = b.width, h = b.height
        let flat = blur(b.flattened(over: RGB(0, 0, 0)), radius: 1.5)
        var mag = [Double](repeating: 0, count: w * h)
        for y in 1..<max(1, h - 1) { for x in 1..<max(1, w - 1) {
            let gx = flat.luma(flat.index(x + 1, y)) - flat.luma(flat.index(x - 1, y))
            let gy = flat.luma(flat.index(x, y + 1)) - flat.luma(flat.index(x, y - 1))
            let ax = Double(b.alpha(x + 1, y)) - Double(b.alpha(x - 1, y)), ay = Double(b.alpha(x, y + 1)) - Double(b.alpha(x, y - 1))
            mag[y * w + x] = max(hypot(gx, gy), hypot(ax, ay))
        } }
        var line = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where mag[i] > 40 { line[i] = 255 }
        line = dilate(line, w: w, h: h, radius: max(1, Int(2.0 / 1024 * unit)))
        var out = Bitmap(width: w, height: h)
        for i in 0..<(w * h) where line[i] > 0 {
            out.pixels[i * 4] = colour.r; out.pixels[i * 4 + 1] = colour.g; out.pixels[i * 4 + 2] = colour.b; out.pixels[i * 4 + 3] = 255
        }
        var glow = blur(out, radius: max(1, 2.0 / 1024 * unit))
        // blur keeps alpha; soften alpha separately
        if let cg = out.alphaAsMask.cgImage {
            let ci = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: max(1, 2.0 / 1024 * unit))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            if let o = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)), let m = Bitmap(cgImage: o) {
                for i in stride(from: 0, to: glow.pixels.count, by: 4) {
                    glow.pixels[i] = colour.r; glow.pixels[i + 1] = colour.g; glow.pixels[i + 2] = colour.b
                    glow.pixels[i + 3] = m.pixels[i]
                }
            }
        }
        return glow
    }

    static func riso(_ b: Bitmap, ink: RGB, mid: Bool, offset: Double, offsetY: Double) -> Bitmap {
        var rng = SplitMix(seed: 7)
        var out = Bitmap(width: b.width, height: b.height)
        let ox = Int(offset.rounded()), oy = Int(offsetY.rounded())
        let flat = b.flattened(over: RGB(255, 255, 255))
        for y in 0..<b.height { for x in 0..<b.width {
            let sx = x - ox, sy = y - oy
            guard sx >= 0, sy >= 0, sx < b.width, sy < b.height else { continue }
            let i = b.index(sx, sy)
            let g = flat.luma(i) / 255
            let a = Double(b.pixels[i + 3]) / 255
            let grain = rng.normal() * 0.08
            let v = mid ? max(0, min(1, (0.88 - g) * 1.8 + grain)) : max(0, min(1, (0.62 - g) * 2.6 + grain))
            let o = out.index(x, y)
            out.pixels[o] = ink.r; out.pixels[o + 1] = ink.g; out.pixels[o + 2] = ink.b; out.pixels[o + 3] = UInt8(v * a * 255)
        } }
        return out
    }

    static func posterize(_ b: Bitmap, colours: Int) -> Bitmap {
        let palette = Palette.clusters(b, k: colours).map(\.colour)
        guard !palette.isEmpty else { return b }
        var out = b
        for i in stride(from: 0, to: b.pixels.count, by: 4) where b.pixels[i + 3] > 0 {
            var best = palette[0], bd = Int.max
            for c in palette {
                let d = (Int(c.r) - Int(b.pixels[i])) * (Int(c.r) - Int(b.pixels[i])) + (Int(c.g) - Int(b.pixels[i + 1])) * (Int(c.g) - Int(b.pixels[i + 1]))
                    + (Int(c.b) - Int(b.pixels[i + 2])) * (Int(c.b) - Int(b.pixels[i + 2]))
                if d < bd { bd = d; best = c }
            }
            out.pixels[i] = best.r; out.pixels[i + 1] = best.g; out.pixels[i + 2] = best.b
        }
        return out
    }

    /// Makes the background colour (the corners') transparent: a logo on a plain ground.
    static func keyBackground(_ b: Bitmap, tolerance: Double) -> Bitmap {
        var cs: [RGB] = []
        for (x, y) in [(0, 0), (b.width - 1, 0), (0, b.height - 1), (b.width - 1, b.height - 1)] {
            let i = b.index(x, y)
            cs.append(RGB(b.pixels[i], b.pixels[i + 1], b.pixels[i + 2]))
        }
        let rs: [UInt8] = cs.map(\.r).sorted(), gs: [UInt8] = cs.map(\.g).sorted(), bs: [UInt8] = cs.map(\.b).sorted()
        let corner = RGB(rs[1], gs[1], bs[1])
        var out = b
        for i in stride(from: 0, to: b.pixels.count, by: 4) {
            let d = sqrt(pow(Double(b.pixels[i]) - Double(corner.r), 2) + pow(Double(b.pixels[i + 1]) - Double(corner.g), 2)
                + pow(Double(b.pixels[i + 2]) - Double(corner.b), 2))
            let a = max(0, min(255, (d - tolerance) * 4))
            out.pixels[i + 3] = UInt8(min(Double(b.pixels[i + 3]), a))
        }
        return out
    }
}

/// A small seeded random source (grain that stays the same between renders).
nonisolated struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func normal() -> Double {
        let u1 = max(1e-12, uniform()), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
