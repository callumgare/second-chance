import CoreGraphics
import Foundation

/// Turns documents into pixels: a layer's content (with its effects), shapes, masks, whole layers on the canvas,
/// and the whole icon (sketch). The real Liquid Glass render is `IconComposer`'s.
nonisolated public struct Renderer: Sendable {
    public let assets: Assets
    public init(assets: Assets) { self.assets = assets }

    /// The content at `pixelWidth`, effects applied. `canvasWidth` is the content's width on the canvas (its
    /// transform's width), so effect sizes in canvas units become pixels.
    /// `transform`: where the layer sits, for masks locked to the canvas (an effect that needs it says so).
    public func content(_ c: Content, program: String, pixelWidth: Int, canvasWidth: Double, transform: Transform? = nil) async throws -> Rendered {
        let pw = max(1, min(4096, pixelWidth))
        switch c {
        case .shape(let s):
            return Rendered(bitmap: Shapes.render(s, size: pw))
        case .image(let ic):
            var src: Bitmap
            if ic.cutout {
                src = try await assets.cutout(program, ic.asset).bitmap
            } else {
                src = try await assets.image(program, ic.asset)
            }
            if let crop = ic.crop, crop.count == 4 {
                let x = Int((crop[0] * Double(src.width)).rounded()), y = Int((crop[1] * Double(src.height)).rounded())
                let w = max(1, Int((crop[2] * Double(src.width)).rounded())), h = max(1, Int((crop[3] * Double(src.height)).rounded()))
                src = src.cropped(x: x, y: y, width: w, height: h)
            }
            let ph = max(1, Int((Double(pw) * Double(src.height) / Double(src.width)).rounded()))
            var r = Rendered(bitmap: src.resized(width: pw, height: ph, pixel: ic.smoothing == "pixel"))
            let unit = Double(pw) / max(0.001, canvasWidth)
            for e in ic.effects where e.on {
                if e.op == "feather" {
                    let softness = max(0, e.t.double("softness", 0.03) * unit), offset = e.t.double("offset", 0) * unit
                    var backing: Bitmap?, backingPad = 0.0
                    // a cut-out (uncropped, nothing drawn outside it yet) moved out shows the picture it came from
                    if offset + softness / 2 > 0.5, ic.crop == nil, r.box == [0, 0, 1, 1],
                       let u = try? await assets.uncut(program, ic.asset, cutout: ic.cutout) {
                        let turned = u.turn % 180 != 0
                        let baseW = Double(turned ? u.box.h : u.box.w)
                        let scale = Double(r.bitmap.width) / max(1, baseW)      // render pixels per picture pixel
                        let padSrc = Int(((offset + softness / 2) / scale).rounded(.up)) + 3
                        let around = u.pic.cropped(x: u.box.x - padSrc, y: u.box.y - padSrc, width: u.box.w + 2 * padSrc, height: u.box.h + 2 * padSrc)
                            .turned(u.turn)
                        backing = around.resized(width: max(1, Int((Double(around.width) * scale).rounded())),
                                                 height: max(1, Int((Double(around.height) * scale).rounded())), pixel: ic.smoothing == "pixel")
                        backingPad = Double(padSrc) * scale
                    }
                    r = Effects.feather(r, softness: softness, offset: offset, backing: backing, backingPad: backingPad)
                } else if e.op == "mask" {
                    r = try await maskEffect(e, r, program: program,
                                             transform: transform ?? Transform(x: 0.5, y: 0.5, width: canvasWidth))
                } else {
                    r = Effects.apply(e, to: r, unit: unit)
                }
            }
            return r
        }
    }

    /// The content's aspect (height / width), without rendering effects.
    public func aspect(_ c: Content, program: String) async throws -> Double {
        switch c {
        case .shape: return 1
        case .image(let ic):
            let src = ic.cutout ? try await assets.cutout(program, ic.asset).bitmap : try await assets.image(program, ic.asset)
            var w = Double(src.width), h = Double(src.height)
            if let crop = ic.crop, crop.count == 4 { w *= crop[2]; h *= crop[3] }
            return h / max(1, w)
        }
    }

    /// A mask, canvas space, `n`×`n`: opaque white where the layer shows.
    public func mask(_ m: Mask, program: String, size n: Int) async throws -> Bitmap {
        let span = Double(n)
        switch m.kind {
        case "ring":
            let outer = m.t.double("outer", 0.43) * span, inner = m.t.double("inner", 0.07) * span
            return Bitmap.draw(width: n, height: n) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.addEllipse(in: CGRect(x: span / 2 - outer, y: span / 2 - outer, width: outer * 2, height: outer * 2))
                ctx.addEllipse(in: CGRect(x: span / 2 - inner, y: span / 2 - inner, width: inner * 2, height: inner * 2))
                ctx.fillPath(using: .evenOdd)
            }
        case "linear-fade":
            let a = m.t.double("angle", 45) * .pi / 180, start = m.t.double("start", 0.25), end = m.t.double("end", 0.7)
            var out = Bitmap(width: n, height: n)
            for y in 0..<n { for x in 0..<n {
                let xx = Double(x) / span - 0.5, yy = Double(y) / span - 0.5
                let t = (xx * cos(a) + yy * sin(a)) / 0.7 + 0.5
                let v = pow(max(0, min(1, (t - start) / max(0.001, end - start))), 1.3)
                let i = out.index(x, y)
                out.pixels[i] = 255; out.pixels[i + 1] = 255; out.pixels[i + 2] = 255; out.pixels[i + 3] = UInt8(v * 255)
            } }
            return out
        case "shape":
            guard let s = m.shape else { return Bitmap(width: n, height: n, fill: (255, 255, 255, 255)) }
            var canvas = Bitmap(width: n, height: n)
            let tr = m.transform ?? .full
            let shape = Shapes.render(s, size: max(1, Int(tr.width * span)))
            place(shape, box: [0, 0, 1, 1], transform: tr, aspect: 1, on: &canvas, pixel: false, opacity: 1)
            if m.t.bool("invert") { for i in stride(from: 3, to: canvas.pixels.count, by: 4) { canvas.pixels[i] = 255 - canvas.pixels[i] } }
            return canvas
        case "image":
            let asset = m.t.string("asset")
            let content = Content.image(ImageContent(asset: asset, cutout: true, crop: m.t.doubles("crop").count == 4 ? m.t.doubles("crop") : nil))
            let tr = m.transform ?? .full
            let pw = max(1, Int(tr.width * span))
            let r = try await self.content(content, program: program, pixelWidth: pw, canvasWidth: tr.width)
            var canvas = Bitmap(width: n, height: n)
            place(r.bitmap, box: r.box, transform: tr, aspect: Double(r.bitmap.height) / Double(r.bitmap.width), on: &canvas, pixel: false, opacity: 1)
            return canvas
        default:
            return Bitmap(width: n, height: n, fill: (255, 255, 255, 255))
        }
    }

    /// A mask effect: `{ op: "mask", mask: <Mask>, lock: "canvas" | "image", invert?: Bool }`. Locked to the canvas
    /// it stays put while the layer moves (drawn on the canvas, mapped back through the layer's transform); locked to
    /// the image it moves, scales and turns with it (its 0…1 coordinates are the picture's own box).
    func maskEffect(_ e: Effect, _ r: Rendered, program: String, transform t: Transform) async throws -> Rendered {
        guard let mv = e.t.values["mask"], let m = try? mv.decode(Mask.self) else { return r }
        let fullW = r.bitmap.width, fullH = r.bitmap.height
        let bw = max(0.0001, r.box[2] - r.box[0]), bh = max(0.0001, r.box[3] - r.box[1])
        let cbW = Double(fullW) / bw, cbH = Double(fullH) / bh            // the content box, in the bitmap's pixels
        let cbX = -r.box[0] * cbW, cbY = -r.box[1] * cbH
        var frame: Bitmap
        if e.t.string("lock", "canvas") == "image" {
            let n = max(16, min(4096, Int(max(cbW, cbH))))
            let sq = try await mask(m, program: program, size: n).resized(width: max(1, Int(cbW)), height: max(1, Int(cbH)))
            frame = Bitmap(width: fullW, height: fullH)
            sq.composite(onto: &frame, rect: CGRect(x: cbX, y: cbY, width: cbW, height: cbH))
        } else {
            let n = max(16, min(4096, Int((cbW / max(0.0001, t.width)).rounded())))   // canvas pixels at this scale
            guard let cm = try await mask(m, program: program, size: n).cgImage else { return r }
            let th = t.rotation * .pi / 180
            frame = Bitmap.draw(width: fullW, height: fullH) { ctx in
                // canvas → the picture's own frame: undo the layer's move and turn
                ctx.translateBy(x: cbX + cbW / 2, y: cbY + cbH / 2)
                ctx.rotate(by: -th)
                ctx.translateBy(x: -t.x * Double(n), y: -t.y * Double(n))
                ctx.drawUpright(cm, in: CGRect(x: 0, y: 0, width: n, height: n))
            }
        }
        if e.t.bool("invert") { for i in stride(from: 3, to: frame.pixels.count, by: 4) { frame.pixels[i] = 255 - frame.pixels[i] } }
        var out = r
        out.bitmap.multiplyAlpha(by: frame)
        return out
    }

    /// Places a rendered content bitmap on a canvas by a transform. `box` is where the bitmap sits relative to the
    /// content's own box (outlines draw outside it).
    public func place(_ b: Bitmap, box: [Double], transform t: Transform, aspect: Double, on canvas: inout Bitmap,
                      pixel: Bool, opacity: Double) {
        let span = Double(canvas.width)
        let cw = t.width * span
        // the content box's height: from the un-padded aspect
        let bw = box[2] - box[0], bh = box[3] - box[1]
        let contentH = Double(b.height) / max(0.0001, bh) * (cw / (Double(b.width) / max(0.0001, bw)))
        _ = aspect
        let cx = t.x * span, cy = t.y * span
        // the bitmap's rect relative to the content box centre
        let x0 = cx - cw / 2 + box[0] * cw, y0 = cy - contentH / 2 + box[1] * contentH
        let rect = CGRect(x: x0, y: y0, width: bw * cw, height: bh * contentH)
        // rotate about the content box's centre, not the bitmap's: offset handled by rotating the bitmap's rect
        // centre around (cx, cy)
        let th = t.rotation * .pi / 180
        let dx = rect.midX - cx, dy = rect.midY - cy
        let rc = CGPoint(x: cx + dx * cos(th) - dy * sin(th), y: cy + dx * sin(th) + dy * cos(th))
        let placed = CGRect(x: rc.x - rect.width / 2, y: rc.y - rect.height / 2, width: rect.width, height: rect.height)
        b.composite(onto: &canvas, rect: placed, rotation: t.rotation, opacity: opacity, pixel: pixel)
    }

    /// One layer on an `n`×`n` canvas: content placed, masked (by its old `mask` and its mask layers), faded.
    public func layer(_ l: Layer, program: String, size n: Int) async throws -> Bitmap {
        var canvas = Bitmap(width: n, height: n)
        let pw = max(1, Int((l.transform.width * Double(n)).rounded()))
        let r = try await content(l.content, program: program, pixelWidth: pw, canvasWidth: l.transform.width, transform: l.transform)
        var pixel = false
        if case .image(let ic) = l.content { pixel = ic.smoothing == "pixel" }
        place(r.bitmap, box: r.box, transform: l.transform, aspect: Double(r.bitmap.height) / Double(r.bitmap.width),
              on: &canvas, pixel: pixel, opacity: l.opacity)
        if let m = l.mask {
            let mb = try await mask(m, program: program, size: n)
            canvas.multiplyAlpha(by: mb)
        }
        // mask layers: the layer shows where each is opaque (or, inverted, where it isn't)
        for m in l.masks ?? [] where m.hidden != true {
            var mb = try await layer(l.placed(m), program: program, size: n)
            if m.invert == true { for i in stride(from: 3, to: mb.pixels.count, by: 4) { mb.pixels[i] = 255 - mb.pixels[i] } }
            canvas.multiplyAlpha(by: mb)
        }
        return canvas
    }

    /// A quick flat picture of the whole icon (no glass): fill, then groups back to front.
    public func sketch(_ doc: Doc, size n: Int, dark: Bool = false) async throws -> Bitmap {
        var canvas = Bitmap(width: n, height: n)
        if doc.fill.kind != .none {
            let c = dark ? (doc.fill.dark ?? doc.fill.color.shade(0.45)) : doc.fill.color
            let shape = doc.fill.kind == .gradient
                ? Shape("gradient", ["from": c.shade(1.12).json, "to": c.shade(0.85).json, "angle": 90])
                : Shape("solid", ["color": c.json])
            canvas = Shapes.render(shape, size: n)
        }
        for g in doc.groups.reversed() where g.hidden != true {
            for l in g.layers.reversed() where l.hidden != true {
                let lb = try await layer(l, program: doc.program, size: n)
                lb.composite(onto: &canvas, rect: CGRect(x: 0, y: 0, width: n, height: n))
            }
        }
        // round the corners as a squircle-ish rounded rect
        let mask = Bitmap.draw(width: n, height: n) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: n, height: n), cornerWidth: Double(n) * 0.225,
                               cornerHeight: Double(n) * 0.225, transform: nil))
            ctx.fillPath()
        }
        canvas.multiplyAlpha(by: mask)
        return canvas
    }
}
