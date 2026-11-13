import CoreImage
import Foundation
import Logging
import ProcessKit
import Vision

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Lab")

/// Parts (docs/api.md "Parts"): what's found in a picture, picking them, editing them, and making new cut-outs.
nonisolated extension Lab {
    public struct PartDTO: Codable, Sendable {
        var id, name, source, kind: String
        var kindSet: Bool?
        var box: [Double]
        var quad: [[Double]]?
        var hasMask: Bool
        var rotation: Int
        var rotationAuto: Bool?
        var rotationWhy: String?
        var picked: Bool
        var size: [Int]?
        var flatSides: [String]?
        var edges: Edges?
        var prompt: JSONValue?
        var image, thumb: String
        var mask: String?
        var frame: String?
    }

    func partDTOs(_ slug: String, _ m: MediaRecord) -> [PartDTO] {
        m.allParts.map { p in
            let base = "/api/programs/\(slug)/media/\(m.id)/parts/\(p.id)"
            let v = Store.sha256(Data((try? JSONEncoder().encode(PartVersion(p, m))) ?? Data())).prefix(8)
            return PartDTO(id: p.id, name: p.name, source: p.source, kind: p.id == "whole" ? m.kind : p.kind, kindSet: p.kindSet, box: p.box,
                           quad: p.quad, hasMask: p.hasMask, rotation: p.id == "whole" ? (m.rotation ?? 0) : p.rotation,
                           rotationAuto: p.id == "whole" ? m.rotationAuto : p.rotationAuto, rotationWhy: p.id == "whole" ? m.rotationWhy : p.rotationWhy,
                           picked: p.picked, size: p.size ?? Lab.estimatedSize(p, m), flatSides: p.flatSides, edges: p.edges, prompt: p.prompt,
                           image: "\(base)/image?v=\(v)", thumb: "\(base)/thumb?v=\(v)", mask: p.hasMask ? "\(base)/mask?v=\(v)" : nil, frame: p.frame)
        }
    }

    /// A part's size before it's been measured: its box at the picture's size, turned.
    static func estimatedSize(_ p: Part, _ m: MediaRecord) -> [Int] {
        let w = max(1, Int(p.box[2] * Double(m.width))), h = max(1, Int(p.box[3] * Double(m.height)))
        let turn = p.id == "whole" ? (m.rotation ?? 0) : p.rotation
        return turn % 180 == 0 ? [w, h] : [h, w]
    }

    /// What changes a part's picture (for cache keys).
    struct PartVersion: Encodable {
        var file: String, rotation: Int, part: String, box: [Double], quad: [[Double]]?, edges: Edges?, mask: Bool, prompt: JSONValue?
        init(_ p: Part, _ m: MediaRecord) {
            file = m.file; rotation = p.id == "whole" ? (m.rotation ?? 0) : p.rotation; part = p.id; box = p.box; quad = p.quad
            edges = p.edges; mask = p.hasMask; prompt = p.prompt
        }
    }

    /// The new analysis's parts, keeping what you did: your parts, and the picks, kinds, names and turns you set.
    func mergeParts(old: [Part], found: [Part], kind: String, rec: MediaRecord) -> [Part] {
        let byId = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var whole = byId["whole"] ?? Part(id: "whole", name: "Whole picture", source: "whole")
        whole.kind = kind
        whole.auto = true
        var out = [whole]
        for var p in found {
            if let o = byId[p.id] {
                p.picked = o.picked
                if o.kindSet == true { p.kind = o.kind; p.kindSet = true }
                if o.rotationAuto == false && o.rotationWhy == nil { p.rotation = o.rotation; p.rotationAuto = false; p.rotationWhy = nil }
                if o.edges != nil { p.edges = o.edges }
            }
            out.append(p)
        }
        out += old.filter { $0.auto == false && $0.id != "whole" }
        return out
    }

    /// Each part's picture size (turned).
    func sizeParts(_ slug: String, _ rec: MediaRecord) async -> MediaRecord {
        var r = rec
        var parts = r.allParts
        for i in parts.indices {
            await assets.forget(slug, "\(rec.id)/\(parts[i].id)")
            if let b = try? await assets.image(slug, "\(rec.id)/\(parts[i].id)") {
                parts[i].size = [b.width, b.height]
                if parts[i].hasMask, parts[i].flatSides == nil, parts[i].rotation == 0,
                   let m = await assets.maskFor(slug, rec.id, parts[i].id) { parts[i].flatSides = Analyser.flatSides(m) }
            }
        }
        r.parts = parts
        return r
    }

    // MARK: Picking and editing

    /// Picks or clears every part (the grid's circle).
    public func pickAll(_ slug: String, _ id: String, _ picked: Bool) async throws -> MediaRecord {
        guard var rec = await store.mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        var parts = rec.allParts
        for i in parts.indices { parts[i].picked = picked }
        rec.parts = parts
        rec.picked = picked
        try await store.upsertMedia(slug, rec)
        if picked, rec.hires == nil || rec.hires == "failed" { await deepen(slug, id) }
        await broadcastMedia(slug, rec)
        return rec
    }

    public struct PartPatch: Decodable, Sendable {
        public var picked: Bool?
        public var kind: String?
        public var rotation: Int?
        public var name: String?
        public var edges: Edges?
        public init(picked: Bool? = nil, kind: String? = nil, rotation: Int? = nil, name: String? = nil, edges: Edges? = nil) {
            self.picked = picked; self.kind = kind; self.rotation = rotation; self.name = name; self.edges = edges
        }
    }

    public func patchPart(_ slug: String, _ id: String, _ partId: String, _ patch: PartPatch) async throws -> MediaRecord {
        guard var rec = await store.mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        var parts = rec.allParts
        guard let i = parts.firstIndex(where: { $0.id == partId }) else { throw IconLabError.notFound("part \(partId)") }
        if let p = patch.picked { parts[i].picked = p }
        if let n = patch.name { parts[i].name = n }
        if let e = patch.edges { parts[i].edges = e }
        if let k = patch.kind {
            parts[i].kind = k; parts[i].kindSet = true
            if partId == "whole" { rec.kind = k; rec.kindSource = "you"; rec.kindSet = true; rec.kindConfidence = 1 }
        }
        if let r = patch.rotation {
            let turn = ((r % 360) + 360) % 360
            parts[i].rotation = turn; parts[i].rotationAuto = false; parts[i].rotationWhy = nil
            if partId == "whole" { rec.rotation = turn; rec.rotationAuto = false; rec.rotationWhy = nil }
        }
        rec.parts = parts
        rec.picked = rec.anyPicked
        try await store.upsertMedia(slug, rec)
        if patch.rotation != nil || patch.edges != nil {
            await assets.forget(slug, id)
            rec = await sizeParts(slug, rec)
            try await store.upsertMedia(slug, rec)
        }
        if patch.picked == true, rec.hires == nil || rec.hires == "failed" { await deepen(slug, id) }
        await broadcastMedia(slug, rec)
        return rec
    }

    public func deletePart(_ slug: String, _ id: String, _ partId: String) async throws -> MediaRecord {
        guard partId != "whole", var rec = await store.mediaRecord(slug, id) else { throw IconLabError.invalid("the whole picture stays") }
        rec.parts = rec.allParts.filter { $0.id != partId }
        rec.picked = rec.anyPicked
        try? FileManager.default.removeItem(at: assets.partMaskFile(slug, id, partId))
        try await store.upsertMedia(slug, rec)
        await assets.forget(slug, id)
        await broadcastMedia(slug, rec)
        return rec
    }

    /// The part's picture as a PNG file (cached by what changes it), or a ≤256 px thumbnail, or its mask.
    public func partFile(_ slug: String, _ id: String, _ partId: String, _ variant: String) async throws -> URL {
        guard let rec = await store.mediaRecord(slug, id), let p = rec.allParts.first(where: { $0.id == partId }) else {
            throw IconLabError.notFound("part \(partId)")
        }
        if variant == "mask" {
            guard let m = await assets.maskFor(slug, id, partId) else { throw IconLabError.notFound("mask") }
            let out = cacheFile("parts", slug, "\(id).\(partId).mask.png")
            try MaskEdges.apply(m, p.edges).writePNG(to: out)
            return out
        }
        let v = Store.sha256(Data((try? JSONEncoder().encode(PartVersion(p, rec))) ?? Data())).prefix(12)
        let out = cacheFile("parts", slug, "\(id).\(partId).\(v).\(variant).png")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let img = try await assets.image(slug, "\(id)/\(partId)")
        if variant == "thumb" {
            let k = min(1, 256 / Double(max(img.width, img.height)))
            try img.resized(width: max(1, Int(Double(img.width) * k)), height: max(1, Int(Double(img.height) * k)),
                            pixel: rec.analysis.pixelArt == true && k >= 1).writePNG(to: out)
        } else {
            try img.writePNG(to: out)
        }
        return out
    }

    // MARK: Making cut-outs

    public struct Candidate: Codable, Sendable {
        var id: String
        var url: String
        var mask: String
        var score: Double
        var box: [Double]
        var area: Double
    }

    func candidateFile(_ slug: String, _ cand: String) -> URL { cacheFile("candidates", slug, "\(Store.slugify(cand)).png") }

    /// Saves a mask as a candidate and returns it with its preview.
    func candidate(_ slug: String, _ id: String, mask: Bitmap, score: Double) async throws -> Candidate {
        let cid = "c-" + UUID().uuidString.lowercased().prefix(10)
        try mask.writePNG(to: candidateFile(slug, cid))
        let pic = try await assets.image(slug, id)
        var m = mask
        if m.width != pic.width || m.height != pic.height { m = m.resized(width: pic.width, height: pic.height) }
        var cut = pic
        cut.multiplyAlpha(by: m, luminance: true)
        let b = cut.alphaBox() ?? (0, 0, pic.width, pic.height)
        let preview = cut.cropped(x: b.x, y: b.y, width: b.w, height: b.h)
        try preview.writePNG(to: cacheFile("candidates", slug, "\(cid).preview.png"))
        var on = 0
        for i in stride(from: 0, to: m.pixels.count, by: 4) where m.pixels[i] > 127 { on += 1 }
        let fullW = Double(pic.width), fullH = Double(pic.height)
        return Candidate(id: String(cid), url: "/api/cache/candidates/\(slug)/\(cid).preview.png",
                         mask: "/api/cache/candidates/\(slug)/\(cid).png", score: (score * 100).rounded() / 100,
                         box: [Double(b.x) / fullW, Double(b.y) / fullH, Double(b.w) / fullW, Double(b.h) / fullH], area: Double(on) / (fullW * fullH))
    }

    /// Vision's subject inside a region: one candidate per instance (and all of them, when there are several).
    public func detect(_ slug: String, _ id: String, region: [Double]) async throws -> [Candidate] {
        let pic = try await assets.image(slug, id)
        let fullW = Double(pic.width), fullH = Double(pic.height)
        let rx = Int(max(0, region[0]) * fullW), ry = Int(max(0, region[1]) * fullH)
        let rw = max(8, Int(min(1, region[2]) * fullW)), rh = max(8, Int(min(1, region[3]) * fullH))
        let crop = pic.cropped(x: rx, y: ry, width: min(rw, pic.width - rx), height: min(rh, pic.height - ry))
        let masks = try await Blocking.run { try Self.subjectMasks(crop) }
        var out: [Candidate] = []
        for (small, all) in masks {
            var full = Bitmap(width: pic.width, height: pic.height, fill: (0, 0, 0, 255))
            for y in 0..<small.height { for x in 0..<small.width {
                let v = small.pixels[small.index(x, y)]
                let t = full.index(x + rx, y + ry)
                full.pixels[t] = v; full.pixels[t + 1] = v; full.pixels[t + 2] = v
            } }
            out.append(try await candidate(slug, id, mask: full, score: all ? 1 : 0.8))
        }
        return out
    }

    /// Vision's subject masks for `crop`, at its size: all its instances together first, then each one when there
    /// are several, each saying whether it is all of them. Blocks while Vision works (`Analyser.analysed`).
    nonisolated private static func subjectMasks(_ crop: Bitmap) throws -> [(mask: Bitmap, all: Bool)] {
        guard let cg = crop.flattened().cgImage else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let r = req.results?.first, !r.allInstances.isEmpty else { return [] }
        var sets: [IndexSet] = [r.allInstances]
        if r.allInstances.count > 1 { sets += r.allInstances.sorted().map { IndexSet(integer: $0) } }
        return sets.compactMap { set in
            guard let buf = try? r.generateScaledMaskForImage(forInstances: set, from: handler),
                  let small = Analyser.bitmap(fromMask: buf, width: crop.width, height: crop.height) else { return nil }
            return (small, set == r.allInstances)
        }
    }

    public struct SegmentPoint: Codable, Sendable { public var x: Double; public var y: Double; public var positive: Bool }

    /// A candidate with its edges applied, for the editor's preview.
    public func previewCandidate(_ slug: String, _ id: String, _ cand: String, edges: Edges) async throws -> (url: String, box: [Double]) {
        guard var m = Bitmap.load(candidateFile(slug, cand)) else { throw IconLabError.notFound("candidate \(cand)") }
        let pic = try await assets.image(slug, id)
        if m.width != pic.width || m.height != pic.height { m = m.resized(width: pic.width, height: pic.height) }
        m = MaskEdges.apply(m, edges)
        var cut = pic
        cut.multiplyAlpha(by: m, luminance: true)
        let b = cut.alphaBox() ?? (0, 0, pic.width, pic.height)
        let name = "\(cand).\(Int(edges.grow)).\(Int(edges.soften * 10)).\(edges.fillHoles ? 1 : 0).png"
        try cut.cropped(x: b.x, y: b.y, width: b.w, height: b.h).writePNG(to: cacheFile("candidates", slug, name))
        let fullW = Double(pic.width), fullH = Double(pic.height)
        return ("/api/cache/candidates/\(slug)/\(name)", [Double(b.x) / fullW, Double(b.y) / fullH, Double(b.w) / fullW, Double(b.h) / fullH])
    }

    public struct PartFromCandidate: Decodable, Sendable {
        public var candidate: String
        public var name: String?
        public var kind: String?
        public var edges: Edges?
        public var prompt: JSONValue?
        public var source: String?
    }

    /// Adds a part from a candidate (picked), or replaces an existing part's mask with it.
    public func savePart(_ slug: String, _ id: String, replacing partId: String?, _ body: PartFromCandidate) async throws -> MediaRecord {
        guard var rec = await store.mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        guard var m = Bitmap.load(candidateFile(slug, body.candidate)) else { throw IconLabError.notFound("candidate \(body.candidate)") }
        let pic = try await assets.image(slug, id)
        if m.width != pic.width || m.height != pic.height { m = m.resized(width: pic.width, height: pic.height) }
        var parts = rec.allParts
        let pid = partId ?? ("p-" + UUID().uuidString.lowercased().prefix(8))
        try m.writePNG(to: assets.partMaskFile(slug, id, pid))
        let box = PartsFinder.maskBox(m) ?? [0, 0, 1, 1]
        if let i = parts.firstIndex(where: { $0.id == pid }) {
            parts[i].hasMask = true; parts[i].box = box; parts[i].quad = nil
            if let e = body.edges { parts[i].edges = e }
            if let pr = body.prompt { parts[i].prompt = pr }
            if let n = body.name { parts[i].name = n }
            parts[i].auto = false
            parts[i].flatSides = nil
        } else {
            var p = Part(id: pid, name: body.name ?? "Cut-out \(parts.count)", source: body.source ?? "region",
                         kind: body.kind ?? "unknown", box: box, hasMask: true, picked: true, auto: false)
            p.edges = body.edges
            p.prompt = body.prompt
            if body.kind != nil { p.kindSet = true }
            parts.append(p)
        }
        rec.parts = parts
        rec.picked = rec.anyPicked
        try await store.upsertMedia(slug, rec)
        await assets.forget(slug, id)
        rec = await sizeParts(slug, rec)
        try await store.upsertMedia(slug, rec)
        await broadcastMedia(slug, rec)
        return rec
    }

    // MARK: Upscaling (design stage)

    public struct AssetInfo: Codable, Sendable { var width: Int; var height: Int; var pixelArt: Bool; var upscaled: [String] }

    public func assetInfo(_ slug: String, _ asset: String) async throws -> AssetInfo {
        let img = try await assets.image(slug, asset)
        guard let ref = AssetRef(asset) else { throw IconLabError.invalid(asset) }
        let rec = await store.mediaRecord(slug, ref.media)
        var made: [String] = []
        for up in ["x4", "px4"] {
            var r = ref; r.upscale = up
            if FileManager.default.fileExists(atPath: assets.upscaledFile(slug, r).path) { made.append(r.string) }
        }
        return AssetInfo(width: img.width, height: img.height, pixelArt: rec?.analysis.pixelArt == true, upscaled: made)
    }

    /// Upscales a part (or picture) ×4 and returns the new asset id.
    public func upscale(_ slug: String, _ asset: String, mode: String) async throws -> (asset: String, width: Int, height: Int) {
        guard var ref = AssetRef(asset) else { throw IconLabError.invalid(asset) }
        ref.upscale = nil
        let base = try await assets.image(slug, ref.string)
        ref.upscale = mode == "pixel" ? "px4" : "x4"
        let file = assets.upscaledFile(slug, ref)
        if let b = Bitmap.load(file) { return (ref.string, b.width, b.height) }
        let big: Bitmap
        if mode == "pixel" {
            big = base.resized(width: base.width * 4, height: base.height * 4, pixel: true)
        } else {
            big = try await models.upscale(base)
        }
        try big.writePNG(to: file)
        await assets.forget(slug, ref.media)
        return (ref.string, big.width, big.height)
    }

    // MARK: Parts for the treatments

    /// The picked parts as records the treatments can choose from (id "<media>/<part>"). A picture with no parts
    /// picked takes no part; when nothing at all is picked, every picture's whole and subject parts stand in.
    public func partRecords(_ slug: String) async -> [MediaRecord] {
        let media = await store.media(slug).filter { $0.derivedFrom == nil && $0.hidden != true }
        let anyPicked = media.contains(where: \.anyPicked)
        var out: [MediaRecord] = []
        for m in media {
            for p in m.allParts where anyPicked ? p.picked : (p.id == "whole" || p.id == "subject") {
                var r = m
                r.id = "\(m.id)/\(p.id)"
                r.picked = true
                if let s = p.size { r.width = s[0]; r.height = s[1] }
                switch p.source {
                case "whole", "frame":
                    r.kind = m.kind == "unknown" ? (m.kindGuesses?.first?.kind ?? "art") : m.kind
                    // the whole picture is a fill, not a figure: its subject is a part of its own
                    r.analysis.scores["silhouette"] = (r.analysis.scores["silhouette"] ?? 0) * 0.3
                    r.analysis.flatSides = []
                case "subject", "instance", "region", "sam":
                    r.kind = "cutout"
                    r.analysis.scores["silhouette"] = max(0.6, m.analysis.scores["silhouette"] ?? 0)
                    r.analysis.scores["fill"] = 0
                    r.analysis.flatSides = p.flatSides ?? []
                    r.analysis.subject = true
                case "text":
                    r.kind = "logo"
                    r.analysis.scores["logo"] = 1
                case "disc":
                    r.kind = "disc"
                    r.analysis.circle = [0.5, 0.5, 0.5]
                    r.analysis.scores["disc"] = 1
                default:
                    r.kind = p.kind == "unknown" ? m.kind : p.kind
                }
                if p.kindSet == true { r.kind = p.kind }
                r.analysis.circle = p.source == "disc" ? [0.5, 0.5, 0.5] : (p.source == "whole" ? m.analysis.circle : nil)
                r.hasMask = false
                out.append(r)
            }
        }
        return out
    }

    /// Gathered "(upscaled)", "(title)", "(straightened)" and "(trimmed)" copies predate parts: remove them.
    public func dropDerivedCopies(_ slug: String) async {
        let media = await store.media(slug)
        let keep = media.filter { $0.derivedFrom == nil }
        guard keep.count != media.count else { return }
        for m in media where m.derivedFrom != nil { try? FileManager.default.removeItem(at: store.mediaFile(slug, m.file)) }
        do { try await store.saveMedia(slug, keep) } catch { logger.error("Couldn't save \(slug)'s media without its derived copies: \(error)") }
    }
}
