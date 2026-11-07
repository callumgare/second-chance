import CoreImage
import CoreML
import Foundation

nonisolated extension Models {
    public static let backgroundRemoval = "birefnet-lite"
    public static let upscaler = "realesrgan-x4plus"

    /// BiRefNet-lite's subject mask for the image: grey (white = subject), the image's size. A second opinion on
    /// Vision's foreground mask; better on box art with text and on hair and fine edges. The model sees the image
    /// stretched to 1024 × 1024, as it was trained.
    public func subjectMask(_ image: Bitmap) async throws -> Bitmap {
        let lm = try await store.model(Self.backgroundRemoval, jobs: jobs)
        guard let input = ModelIO.input(lm.model, .multiArray) else { throw IconLabError.tool("\(Self.backgroundRemoval) has no input") }
        let shape = input.multiArrayConstraint?.shape.map(\.intValue) ?? [1, 3, 1024, 1024]
        let side = shape.count == 4 ? shape[3] : 1024
        let x = try ModelIO.planar(image.flattened().resized(width: side, height: side),
                                   mean: [0.485, 0.456, 0.406], std: [0.229, 0.224, 0.225])
        let out = try await lm.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.name: MLFeatureValue(multiArray: x)]))
        guard let name = lm.model.modelDescription.outputDescriptionsByName.keys.first,
              let a = out.featureValue(for: name)?.multiArrayValue else { throw IconLabError.tool("no mask from \(Self.backgroundRemoval)") }
        let logits = ModelIO.floats(a)
        var mask = Bitmap(width: side, height: side)
        for i in 0..<min(logits.count, side * side) {
            let v = UInt8(max(0, min(255, (1 / (1 + exp(-logits[i]))) * 255)))
            mask.pixels[i * 4] = v; mask.pixels[i * 4 + 1] = v; mask.pixels[i * 4 + 2] = v; mask.pixels[i * 4 + 3] = 255
        }
        return mask.resized(width: image.width, height: image.height)
    }

    /// Real-ESRGAN ×4 (2 is ×4 then halved). For photos, scans and low-resolution box art; pixel art should stay
    /// nearest-neighbour (`Bitmap.resized(…, pixel: true)`). Runs in 256-pixel tiles that overlap by 16 so seams
    /// don't show, so memory stays bounded whatever the size; the output may be at most 64 megapixels. Alpha is
    /// scaled smoothly on its own.
    public func upscale(_ image: Bitmap, factor: Int = 4) async throws -> Bitmap {
        guard factor == 2 || factor == 4 else { throw IconLabError.invalid("upscale factor \(factor) (2 or 4)") }
        guard image.width * image.height * 16 <= 64_000_000 else { throw IconLabError.invalid("\(image.width)×\(image.height) is too big to upscale ×4") }
        let lm = try await store.model(Self.upscaler, jobs: jobs)
        let m = lm.model
        guard let input = m.modelDescription.inputDescriptionsByName.values.first,
              let outName = m.modelDescription.outputDescriptionsByName.keys.first else { throw IconLabError.tool("\(Self.upscaler) has no input") }
        let tile = input.multiArrayConstraint?.shape.last?.intValue ?? input.imageConstraint?.pixelsWide ?? 256
        let pad = 16, step = tile - 2 * pad, scale = 4
        // The model sees no alpha. Flattened over white, a cut-out's soft edge turns light and the model sharpens it
        // into a white rim; so its partly clear pixels keep their own colour and the clear ones take the colours
        // around them (alpha goes back on afterwards).
        let src = Self.opaque(image)
        var out = Bitmap(width: src.width * scale, height: src.height * scale, fill: (0, 0, 0, 255))
        var ty = 0
        while ty < src.height {
            var tx = 0
            while tx < src.width {
                // the tile around (tx, ty)…(tx+step, ty+step), with `pad` of context each side, edges repeated
                let ox = tx - pad, oy = ty - pad
                let t = Self.tileClamped(src, x: ox, y: oy, size: tile)
                let value: MLFeatureValue
                if input.type == .image {
                    value = MLFeatureValue(pixelBuffer: try ModelIO.pixelBuffer(t))
                } else {
                    value = MLFeatureValue(multiArray: try ModelIO.planar(t, type: input.multiArrayConstraint?.dataType ?? .float32))
                }
                let r = try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.name: value]))
                guard let fv = r.featureValue(for: outName) else { throw IconLabError.tool("no output from \(Self.upscaler)") }
                let big: (Int) -> (UInt8, UInt8, UInt8)   // pixel i of the tile × 4
                let bw = tile * scale
                if let a = fv.multiArrayValue {
                    let f = ModelIO.floats(a), plane = bw * bw
                    big = { i in (Self.byte(f[i]), Self.byte(f[plane + i]), Self.byte(f[2 * plane + i])) }
                } else if let pb = fv.imageBufferValue, let b = Self.bitmap(pb) {
                    big = { i in (b.pixels[i * 4], b.pixels[i * 4 + 1], b.pixels[i * 4 + 2]) }
                } else { throw IconLabError.tool("unexpected output from \(Self.upscaler)") }
                // copy the tile's middle (the step × step part) into place
                let w = min(step, src.width - tx), h = min(step, src.height - ty)
                for y in 0..<(h * scale) {
                    for x in 0..<(w * scale) {
                        let (r, g, b) = big((pad * scale + y) * bw + pad * scale + x)
                        let o = out.index(tx * scale + x, ty * scale + y)
                        out.pixels[o] = r; out.pixels[o + 1] = g; out.pixels[o + 2] = b
                    }
                }
                tx += step
            }
            ty += step
        }
        if image.pixels.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element < 255 }) {
            let alpha = image.alphaAsMask.resized(width: out.width, height: out.height)
            for i in stride(from: 0, to: out.pixels.count, by: 4) { out.pixels[i + 3] = alpha.pixels[i] }
        }
        return factor == 4 ? out : out.resized(width: image.width * 2, height: image.height * 2)
    }

    /// Opaque, each clear pixel taking the colour of what's nearest (wider and wider blurs, premultiplied, so only
    /// the picture's own colours spread), each partly clear one its own colour.
    static func opaque(_ image: Bitmap) -> Bitmap {
        var out = image
        let n = image.width * image.height
        guard (0..<n).contains(where: { image.pixels[$0 * 4 + 3] < 255 }) else { return image }
        var filled = (0..<n).map { image.pixels[$0 * 4 + 3] > 0 }
        var sigma = 2.0
        while filled.contains(false), sigma < Double(max(image.width, image.height)) * 2 {
            let bl = Effects.blurAll(image, sigma: sigma)
            for i in 0..<n where !filled[i] && bl.pixels[i * 4 + 3] > 0 {
                for k in 0..<3 { out.pixels[i * 4 + k] = bl.pixels[i * 4 + k] }
                filled[i] = true
            }
            sigma *= 2
        }
        for i in 0..<n { out.pixels[i * 4 + 3] = 255 }
        return out
    }

    static func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

    /// A size × size piece starting at (x, y), with pixels outside the image taken from its nearest edge.
    static func tileClamped(_ b: Bitmap, x: Int, y: Int, size: Int) -> Bitmap {
        var t = Bitmap(width: size, height: size)
        for j in 0..<size {
            let sy = min(max(y + j, 0), b.height - 1)
            for i in 0..<size {
                let sx = min(max(x + i, 0), b.width - 1)
                let s = b.index(sx, sy), d = t.index(i, j)
                t.pixels[d] = b.pixels[s]; t.pixels[d + 1] = b.pixels[s + 1]; t.pixels[d + 2] = b.pixels[s + 2]; t.pixels[d + 3] = 255
            }
        }
        return t
    }

    static func bitmap(_ pb: CVPixelBuffer) -> Bitmap? {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return Bitmap(cgImage: cg)
    }
}
