import CoreImage
import Foundation

/// A program's images as the renderers need them: the picture, its subject mask, and the cut-out (cropped to the
/// subject). Loaded once and kept in memory.
public actor Assets {
    let store: Store
    private var images: [String: Bitmap] = [:]
    private var cutouts: [String: Cutout] = [:]

    public struct Cutout: Sendable {
        public var bitmap: Bitmap
        /// Where the cut-out was in the full image, in pixels.
        public var box: (x: Int, y: Int, w: Int, h: Int)
    }

    public init(store: Store) { self.store = store }

    public func image(_ program: String, _ id: String) async throws -> Bitmap {
        let key = program + "/" + id
        if let b = images[key] { return b }
        if let ref = AssetRef(id), ref.part != nil || ref.upscale != nil {
            let b = try await partImage(program, ref)
            images[key] = b
            return b
        }
        guard let rec = await store.mediaRecord(program, id) else { throw IconLabError.notFound("media \(id)") }
        guard let b = Bitmap.load(store.mediaFile(program, rec.file)) else { throw IconLabError.notFound("image \(rec.file)") }
        images[key] = b
        return b
    }

    public func mask(_ program: String, _ id: String) async -> Bitmap? {
        let url = store.maskFile(program, id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Bitmap.load(url)
    }

    /// The image cut to its subject (hard-edged mask times its own alpha), cropped to the cut-out.
    public func cutout(_ program: String, _ id: String) async throws -> Cutout {
        let key = program + "/" + id
        if let c = cutouts[key] { return c }
        if let ref = AssetRef(id), ref.part != nil || ref.upscale != nil {
            // a part is already what it is: cropped to whatever it shows
            let img = try await image(program, id)
            let box = img.alphaBox() ?? (0, 0, img.width, img.height)
            let c = Cutout(bitmap: img.cropped(x: box.x, y: box.y, width: box.w, height: box.h), box: box)
            cutouts[key] = c
            return c
        }
        var img = try await image(program, id)
        if var m = await mask(program, id) {
            if m.width != img.width || m.height != img.height { m = m.resized(width: img.width, height: img.height) }
            for i in stride(from: 0, to: m.pixels.count, by: 4) {
                let v: UInt8 = m.pixels[i] > 127 ? 255 : 0
                m.pixels[i] = v; m.pixels[i + 1] = v; m.pixels[i + 2] = v
            }
            img.multiplyAlpha(by: m, luminance: true)
        }
        let box = img.alphaBox() ?? (0, 0, img.width, img.height)
        let c = Cutout(bitmap: img.cropped(x: box.x, y: box.y, width: box.w, height: box.h), box: box)
        cutouts[key] = c
        return c
    }

    public func forget(_ program: String, _ id: String) {
        for k in images.keys where k == program + "/" + id || k.hasPrefix(program + "/" + id + "/") || k.hasPrefix(program + "/" + id + "@") { images[k] = nil }
        for k in cutouts.keys where k == program + "/" + id || k.hasPrefix(program + "/" + id + "/") || k.hasPrefix(program + "/" + id + "@") { cutouts[k] = nil }
    }

    /// A part's mask file: `masks/<media>.<part>.png` (the subject's is also `masks/<media>.png`).
    public nonisolated func partMaskFile(_ program: String, _ media: String, _ part: String) -> URL {
        store.dir(program).appendingPathComponent("masks").appendingPathComponent("\(media).\(part).png")
    }

    /// Where an upscaled asset is kept.
    public nonisolated func upscaledFile(_ program: String, _ ref: AssetRef) -> URL {
        store.root.appendingPathComponent("cache/upscaled/\(program)/\(Store.slugify(ref.media))-\(ref.part.map(Store.slugify) ?? "media")-\(ref.upscale ?? "").png")
    }

    func maskFor(_ program: String, _ media: String, _ part: String) async -> Bitmap? {
        if let m = Bitmap.load(partMaskFile(program, media, part)) { return m }
        return part == "subject" ? await mask(program, media) : nil
    }

    /// Where a cut-out sits in the picture it was cut from: that picture (unturned), the cut-out's box in it, and the
    /// turn applied after cutting. Nil when the asset isn't a cut-out (a whole picture, a crop, a straightened rect).
    /// An upscaled asset answers for its original. Lets a feather moved outwards show the picture around the cut-out.
    public func uncut(_ program: String, _ id: String, cutout: Bool) async throws -> (pic: Bitmap, box: (x: Int, y: Int, w: Int, h: Int), turn: Int)? {
        guard var ref = AssetRef(id) else { return nil }
        ref.upscale = nil
        guard let partId = ref.part else {
            guard cutout else { return nil }
            let pic = try await image(program, ref.media)
            return (pic, try await self.cutout(program, ref.media).box, 0)
        }
        guard let rec = await store.mediaRecord(program, ref.media),
              let part = rec.allParts.first(where: { $0.id == partId }), part.id != "whole", part.file == nil,
              part.hasMask, var m = await maskFor(program, ref.media, part.id) else { return nil }
        var pic = try await image(program, ref.media)
        if let f = part.frame, let fp = rec.allParts.first(where: { $0.id == f }), let ff = fp.file,
           let b = Bitmap.load(store.mediaFile(program, ff)) { pic = b }
        if m.width != pic.width || m.height != pic.height { m = m.resized(width: pic.width, height: pic.height) }
        m = MaskEdges.apply(m, part.edges)
        var cut = pic
        cut.multiplyAlpha(by: m, luminance: true)
        let b = cut.alphaBox() ?? (0, 0, pic.width, pic.height)
        return (pic, b, part.rotation)
    }

    /// A part as a picture: the picture (or a crop, a straightened rectangle, or a cut-out of it), turned.
    func partImage(_ program: String, _ ref: AssetRef) async throws -> Bitmap {
        if let up = ref.upscale {
            let f = upscaledFile(program, ref)
            if let b = Bitmap.load(f) { return b }
            _ = up
            // not made yet: the original stands in
            return try await partImage(program, AssetRef(media: ref.media, part: ref.part, upscale: nil))
        }
        guard let rec = await store.mediaRecord(program, ref.media) else { throw IconLabError.notFound("media \(ref.media)") }
        var pic = try await image(program, ref.media)
        let partId = ref.part ?? "whole"
        guard let part = rec.allParts.first(where: { $0.id == partId }) else { throw IconLabError.notFound("part \(partId)") }
        // a cut-out from another frame of a video is cut from that frame's picture
        if let f = part.frame, let fp = rec.allParts.first(where: { $0.id == f }), let ff = fp.file,
           let b = Bitmap.load(store.mediaFile(program, ff)) { pic = b }
        let fullW = Double(pic.width), fullH = Double(pic.height)
        var out: Bitmap
        if let own = part.file, let b = Bitmap.load(store.mediaFile(program, own)) {
            out = b
        } else if part.id == "whole" {
            out = pic
        } else if part.hasMask, var m = await maskFor(program, ref.media, part.id) {
            if m.width != pic.width || m.height != pic.height { m = m.resized(width: pic.width, height: pic.height) }
            m = MaskEdges.apply(m, part.edges)
            var cut = pic
            cut.multiplyAlpha(by: m, luminance: true)
            let b = cut.alphaBox() ?? (0, 0, pic.width, pic.height)
            out = cut.cropped(x: b.x, y: b.y, width: b.w, height: b.h)
        } else if let q = part.quad, q.count == 4, let cg = pic.cgImage {
            func p(_ v: [Double]) -> CIVector { CIVector(x: v[0] * fullW, y: (1 - v[1]) * fullH) }
            let ci = CIImage(cgImage: cg).applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": p(q[0]), "inputTopRight": p(q[1]), "inputBottomRight": p(q[2]), "inputBottomLeft": p(q[3]),
            ])
            guard let o = CIContext().createCGImage(ci, from: ci.extent), let b = Bitmap(cgImage: o) else { throw IconLabError.tool("couldn't straighten") }
            out = b
        } else {
            let b = part.box
            out = pic.cropped(x: Int(b[0] * fullW), y: Int(b[1] * fullH), width: max(1, Int(b[2] * fullW)), height: max(1, Int(b[3] * fullH)))
        }
        let turn = part.id == "whole" ? (rec.rotation ?? part.rotation) : part.rotation
        return out.turned(turn)
    }
}

/// An asset id: `<media>`, `<media>/<part>`, either with `@x4` (upscaled photo) or `@px4` (pixel art) appended.
nonisolated public struct AssetRef: Sendable, Hashable {
    public var media: String
    public var part: String?
    public var upscale: String?

    public init(media: String, part: String?, upscale: String?) { self.media = media; self.part = part; self.upscale = upscale }

    public init?(_ s: String) {
        var base = s
        if let at = s.lastIndex(of: "@") { upscale = String(s[s.index(after: at)...]); base = String(s[..<at]) }
        let bits = base.split(separator: "/", maxSplits: 1).map(String.init)
        guard let m = bits.first, !m.isEmpty else { return nil }
        media = m
        part = bits.count > 1 ? bits[1] : nil
    }

    public var string: String { media + (part.map { "/" + $0 } ?? "") + (upscale.map { "@" + $0 } ?? "") }
}
