import CoreGraphics
import CoreText
import Foundation

/// Canvas-space shapes, drawn at `n`×`n` pixels. Coordinates in the first lab were for a 1024 canvas; `k` scales
/// them.
nonisolated public enum Shapes {
    public static func render(_ shape: Shape, size n: Int) -> Bitmap {
        let t = shape.t
        let k = Double(n) / 1024
        return Bitmap.draw(width: n, height: n) { ctx in
            let full = CGRect(x: 0, y: 0, width: n, height: n)
            switch shape.type {
            case "solid":
                ctx.setFillColor(t.colour("color").cgColor)
                ctx.fill(full)
            case "gradient":
                let from = t.colour("from"), to = t.colour("to", RGB(255, 255, 255))
                let a = t.double("angle", 90) * .pi / 180
                guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from.cgColor, to.cgColor] as CFArray,
                                         locations: [0, 1]) else { return }
                let c = Double(n) / 2, r = Double(n) / 2
                ctx.drawLinearGradient(g, start: CGPoint(x: c - cos(a) * r, y: c - sin(a) * r),
                                       end: CGPoint(x: c + cos(a) * r, y: c + sin(a) * r), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case "pattern":
                pattern(ctx, kind: t.string("pattern", "stripes"), a: t.colour("a"), b: t.colour("b", RGB(255, 255, 255)), k: k, n: n)
            case "bands":
                let cs = t.colours("colors")
                for (i, c) in cs.enumerated() {
                    ctx.setFillColor(c.cgColor)
                    ctx.fill(CGRect(x: 0, y: Double(n) * Double(i) / Double(cs.count), width: Double(n), height: Double(n) / Double(cs.count) + 1))
                }
            case "window":
                let frame = t.colour("frame", RGB(240, 240, 240)), bar = t.colour("bar", RGB(60, 90, 160))
                let x0 = 120 * k, y0 = 170 * k, x1 = 904 * k, y1 = 880 * k
                let outer = CGPath(roundedRect: CGRect(x: x0 - 14 * k, y: y0 - 90 * k, width: x1 - x0 + 28 * k, height: y1 - y0 + 104 * k),
                                   cornerWidth: 28 * k, cornerHeight: 28 * k, transform: nil)
                ctx.addPath(outer)
                ctx.addRect(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                ctx.setFillColor(frame.cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.saveGState()
                ctx.addPath(outer); ctx.clip()
                ctx.setFillColor(bar.cgColor)
                ctx.fill(CGRect(x: x0 - 14 * k, y: y0 - 90 * k, width: x1 - x0 + 28 * k, height: 80 * k))
                ctx.restoreGState()
                for (i, c) in [RGB(255, 95, 87), RGB(254, 188, 46), RGB(40, 200, 64)].enumerated() {
                    ctx.setFillColor(c.cgColor)
                    ctx.fillEllipse(in: CGRect(x: x0 + 14 * k + Double(i) * 52 * k, y: y0 - 66 * k, width: 36 * k, height: 36 * k))
                }
            case "crt":
                let bezel = t.colour("bezel", RGB(60, 60, 70))
                let x0 = 150 * k, y0 = 190 * k, x1 = 874 * k, y1 = 760 * k
                ctx.addPath(CGPath(roundedRect: CGRect(x: 90 * k, y: 130 * k, width: 844 * k, height: 700 * k), cornerWidth: 110 * k, cornerHeight: 110 * k, transform: nil))
                ctx.addPath(CGPath(roundedRect: CGRect(x: x0 - 6 * k, y: y0 - 6 * k, width: x1 - x0 + 12 * k, height: y1 - y0 + 12 * k),
                                   cornerWidth: 76 * k, cornerHeight: 76 * k, transform: nil))
                ctx.setFillColor(bezel.shade(0.8).cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.setFillColor(bezel.shade(0.6).cgColor)
                ctx.fill(CGRect(x: 380 * k, y: 830 * k, width: 264 * k, height: 70 * k))
            case "disc-rims":
                let c = t.colour("color", RGB(255, 255, 255))
                ctx.setStrokeColor(c.cgColor.copy(alpha: 0.55) ?? c.cgColor)
                ctx.setLineWidth(60 * k)
                ctx.strokeEllipse(in: CGRect(x: 512 * k - 120 * k, y: 512 * k - 120 * k, width: 240 * k, height: 240 * k))
                ctx.setStrokeColor(c.cgColor.copy(alpha: 0.35) ?? c.cgColor)
                ctx.setLineWidth(12 * k)
                ctx.strokeEllipse(in: CGRect(x: 78 * k, y: 78 * k, width: 868 * k, height: 868 * k))
            case "text":
                text(ctx, t.string("text", "A"), font: t.string("font", "Arial Black"), size: t.double("size", 0.86) * Double(n),
                     colour: t.colour("color", RGB(255, 255, 255)), n: n)
            case "rounded-rect":
                let r = t.doubles("rect")
                guard r.count == 4 else { return }
                ctx.setFillColor(t.colour("color", RGB(255, 255, 255)).cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: r[0] * Double(n), y: r[1] * Double(n), width: r[2] * Double(n), height: r[3] * Double(n)),
                                   cornerWidth: t.double("radius", 0.06) * Double(n), cornerHeight: t.double("radius", 0.06) * Double(n), transform: nil))
                ctx.fillPath()
            case "circle":
                let r = t.double("radius", 0.4) * Double(n)
                ctx.setFillColor(t.colour("color", RGB(255, 255, 255)).cgColor)
                ctx.fillEllipse(in: CGRect(x: Double(n) / 2 - r, y: Double(n) / 2 - r, width: r * 2, height: r * 2))
            default:
                break
            }
        }
    }

    static func pattern(_ ctx: CGContext, kind: String, a: RGB, b: RGB, k: Double, n: Int) {
        let span = Double(n)
        ctx.setFillColor(a.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: span, height: span))
        ctx.setFillColor(b.cgColor)
        ctx.setStrokeColor(b.cgColor)
        switch kind {
        case "stripes":
            var i = -span
            while i < 2 * span {
                ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i + 48 * k, y: 0))
                ctx.addLine(to: CGPoint(x: i + 48 * k - span, y: span)); ctx.addLine(to: CGPoint(x: i - span, y: span)); ctx.closePath()
                i += 96 * k
            }
            ctx.fillPath()
        case "dots":
            var y = 0.0, row = 0
            while y < span + 64 * k {
                var x = 0.0
                while x < span + 64 * k {
                    let o = row % 2 == 1 ? 32 * k : 0
                    ctx.fillEllipse(in: CGRect(x: x + o - 14 * k, y: y - 14 * k, width: 28 * k, height: 28 * k))
                    x += 64 * k
                }
                y += 64 * k; row += 1
            }
        case "grid":
            ctx.setLineWidth(6 * k)
            var i = 0.0
            while i < span {
                ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: span))
                ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: span, y: i))
                i += 80 * k
            }
            ctx.strokePath()
        case "rays":
            let c = CGPoint(x: span * 0.9, y: span * 0.9)
            for deg in stride(from: 0, to: 360, by: 12) {
                let r = Double(deg) * .pi / 180
                ctx.move(to: c)
                ctx.addLine(to: CGPoint(x: c.x + 2000 * k * cos(r), y: c.y + 2000 * k * sin(r)))
                ctx.addLine(to: CGPoint(x: c.x + 2000 * k * cos(r + 0.1), y: c.y + 2000 * k * sin(r + 0.1)))
                ctx.closePath()
            }
            ctx.fillPath()
        case "checker":
            var y = 0.0
            while y < span {
                var x = 0.0
                while x < span {
                    if (Int(x / (128 * k)) + Int(y / (128 * k))) % 2 == 1 { ctx.fill(CGRect(x: x, y: y, width: 128 * k, height: 128 * k)) }
                    x += 128 * k
                }
                y += 128 * k
            }
        default:
            break
        }
    }

    /// A line of text centred on the canvas by its glyphs' bounds (a monogram letter sits optically centred).
    static func text(_ ctx: CGContext, _ s: String, font: String, size: Double, colour: RGB, n: Int) {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f,
                                                     .init(kCTForegroundColorAttributeName as String): colour.cgColor]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        // The context is y-down; Core Text draws y-up.
        ctx.translateBy(x: 0, y: CGFloat(n))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: (Double(n) - bounds.width) / 2 - bounds.minX, y: (Double(n) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
