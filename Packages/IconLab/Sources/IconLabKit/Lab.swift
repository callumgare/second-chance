import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Lab")

/// The engine: store, assets, renderers and jobs, and the operations the API offers.
nonisolated public final class Lab: Sendable {
    public let store: Store
    public let assets: Assets
    public let renderer: Renderer
    public let composer: IconComposer
    public let jobs: Jobs
    public let env: Env
    public let tools: LabTools
    public let host: LabHostInfo
    public let downloader = Downloader()

    /// `dataDir` holds everything Icon Lab keeps; `env` its keys; `tools` the programs and places it uses from outside;
    /// `host` what the host knows of programs and their bundles.
    public init(dataDir: URL, env: Env = Env(file: nil), tools: LabTools = LabTools(), host: LabHostInfo = LabHostInfo()) {
        self.env = env
        self.tools = tools
        self.host = host
        store = Store(root: dataDir)
        assets = Assets(store: store)
        renderer = Renderer(assets: assets)
        composer = IconComposer(renderer: renderer, cacheDir: dataDir.appendingPathComponent("cache"), ictool: tools.ictool)
        jobs = Jobs(width: max(2, ProcessInfo.processInfo.activeProcessorCount / 3))
    }

    // MARK: DTOs

    public struct MediaDTO: Codable, Sendable {
        var id, name, kind, source: String
        var kindConfidence: Double
        var sourceUrl, provenance: String?
        var width, height: Int
        var url, thumb: String
        var cutout, mask: String?
        var picked: Bool
        var analysis: MediaAnalysis
        var suitability: Double
        /// What `suitability` adds up, for the inspector.
        var suitabilityFactors: [SuitabilityFactor]
        var remote: RemoteMedia?
        var hires: String?
        var duplicateOf: String?
        var derivedFrom: String?
        var cutoutSize: [Int]?
        var relevance: Double?
        var relevanceWhy: [String]?
        var upgraded: Bool?
        var hidden: Bool?
        var deep: [String: JSONValue]?
        var kindSource: String?
        var kindGuesses: [KindGuess]?
        var sourceLabel: String?
        var rotation: Int
        var rotationAuto: Bool?
        var rotationWhy: String?
        var parts: [PartDTO]
        var link: SourceLinks.Link?
    }

    public func dto(_ slug: String, _ m: MediaRecord) -> MediaDTO {
        let base = "/api/programs/\(slug)/media/\(m.id)"
        return MediaDTO(id: m.id, name: m.name, kind: m.kind, source: m.source, kindConfidence: m.kindConfidence,
                        sourceUrl: m.sourceUrl, provenance: m.provenance, width: m.width, height: m.height,
                        url: "\(base)/image", thumb: "\(base)/thumb", cutout: m.hasMask ? "\(base)/cutout" : nil,
                        mask: m.hasMask ? "\(base)/mask" : nil, picked: m.anyPicked, analysis: m.analysis,
                        // worked out afresh each time, so a change to the scoring reaches every picture at once
                        suitability: Lab.suitability(m), suitabilityFactors: Lab.suitabilityFactors(m),
                        remote: m.remote, hires: m.hires, duplicateOf: m.duplicateOf, derivedFrom: m.derivedFrom, cutoutSize: m.cutoutSize,
                        relevance: m.relevance, relevanceWhy: m.relevanceWhy, upgraded: m.upgraded, hidden: m.hidden, deep: m.deep,
                        kindSource: m.kindSource, kindGuesses: m.kindGuesses, sourceLabel: m.sourceLabel ?? m.remote?.sourceLabel,
                        rotation: m.rotation ?? 0, rotationAuto: m.rotationAuto, rotationWhy: m.rotationWhy, parts: partDTOs(slug, m),
                        link: SourceLinks.link(for: m, programTitle: programTitle(slug)))
    }

    public struct ProgramDTO: Codable, Sendable {
        var slug, title: String
        var year: Int?
        var bundleId: String?
        var media: [MediaDTO]
        var colours: [String: String]
        var colourOrder: [String]
        var roles: [String: String]
    }

    public func program(_ slug: String) async throws -> ProgramDTO {
        guard let p = await store.program(slug) else { throw IconLabError.notFound("program \(slug)") }
        let media = await store.media(slug)
        let roles = Treatments.defaultRoles(media)
        let (colours, order) = Lab.mergeSameColours(await colourOptions(slug, subject: roles["subject"], media: media))
        return ProgramDTO(slug: slug, title: p.title, year: p.year, bundleId: p.bundleId, media: media.map { dto(slug, $0) }, colours: colours,
                          colourOrder: order, roles: roles)
    }

    /// What follows from a program's pictures rather than being one of them: its colours and the pictures in each
    /// role. They change as gathering and analysis go on, so the page asks again when its pictures change.
    public struct ProgramLook: Codable, Sendable {
        var colours: [String: String]
        var colourOrder: [String]
        var roles: [String: String]
    }

    public func look(_ slug: String) async throws -> ProgramLook {
        guard await store.program(slug) != nil else { throw IconLabError.notFound("program \(slug)") }
        let media = await store.media(slug)
        let roles = Treatments.defaultRoles(media)
        let (colours, order) = Lab.mergeSameColours(await colourOptions(slug, subject: roles["subject"], media: media))
        return ProgramLook(colours: colours, colourOrder: order, roles: roles)
    }

    /// Options that are the same colour show once, named for all of them ("dominant & lightest"), in order of first
    /// appearance.
    static func mergeSameColours(_ c: ([String: String], [String])) -> ([String: String], [String]) {
        let (colours, order) = c
        var namesByHex: [String: [String]] = [:], hexOrder: [String] = []
        for n in order {
            guard let h = colours[n]?.lowercased() else { continue }
            if namesByHex[h] == nil { hexOrder.append(h) }
            namesByHex[h, default: []].append(n)
        }
        var outColours: [String: String] = [:], outOrder: [String] = []
        for h in hexOrder {
            let names = namesByHex[h] ?? []
            let name = names.count <= 2 ? names.joined(separator: " & ") : names.dropLast().joined(separator: ", ") + " & " + (names.last ?? "")
            outColours[name] = h
            outOrder.append(name)
        }
        return (outColours, outOrder)
    }

    /// 0…5, worked out afresh: the picture's own measures (kind, size, subject) and, for an image found in your
    /// files, half from where the extractor found it (its rank: the program's own icon ranks far above a bitmap of
    /// a printable map, whatever their sizes). A picture added by hand is a 5. Everything that ranks pictures uses
    /// this, the suggestions as well as the page, so they agree.
    static func suitability(_ m: MediaRecord) -> Double {
        SuitabilityFactor.total(suitabilityFactors(m))
    }

    /// What `suitability` adds up: for a ranked picture, its own factors at half their points, and its rank's half.
    static func suitabilityFactors(_ m: MediaRecord) -> [SuitabilityFactor] {
        // a picture the person added by hand is what they chose: the top of the scale
        if m.deep?["byHand"] == .bool(true) { return [.init("Added by you", 5)] }
        var own = Analyser.suitabilityFactors(m.analysis, kind: m.kind == "unknown" ? (m.kindGuesses?.first?.kind ?? "unknown") : m.kind,
                                              width: m.width, height: m.height)
        let sum = own.reduce(0) { $0 + $1.points }
        let kept = max(0, min(5, sum))
        if kept != sum { own.append(.init(sum > 5 ? "Kept to at most 5" : "Kept to at least 0", kept - sum)) }
        guard let rank = m.deep?["extractScore"]?.doubleValue else { return own }
        let fromRank = max(0, min(5, rank / 25))   // 125 points and more is a 5
        var details = ["\(Int(rank.rounded())) points from scanning the program's files; 125 or more counts in full"]
        if case .array(let reasons)? = m.deep?["scoreReasons"] {
            details += reasons.compactMap { if case .string(let r) = $0 { r } else { nil } }
        }
        return own.map { SuitabilityFactor($0.label, $0.points / 2, details: $0.details) }
            + [.init("How likely it's the program's own icon, by where it was found", fromRank / 2, details: details)]
    }

    struct ColourCache: Codable { var subject: String; var file: String; var colours: [String: String]; var order: [String] }

    /// The named colour options, from the subject image: cached in the program's folder until the subject changes.
    func colourOptions(_ slug: String, subject: String?, media: [MediaRecord]) async -> ([String: String], [String]) {
        guard let sid = subject, let rec = media.first(where: { $0.id == sid }) else { return ([:], []) }
        let cacheURL = store.dir(slug).appendingPathComponent("colours.json")
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(ColourCache.self, from: d),
           c.subject == sid, c.file == rec.file { return (c.colours, c.order) }
        guard let img = Bitmap.loadThumbnail(store.mediaFile(slug, rec.file), maxPixel: 384) else { return ([:], []) }
        var colours: [String: String] = [:], order: [String] = []
        for (n, c) in Palette.options(img) { colours[n] = c.hex; order.append(n) }
        do { try JSONEncoder().encode(ColourCache(subject: sid, file: rec.file, colours: colours, order: order)).write(to: cacheURL) } catch {
            logger.warning("Couldn't keep \(slug)'s colours: \(error)")
        }
        return (colours, order)
    }

    public struct ProgramSummary: Codable, Sendable {
        public var slug: String
        var title: String
        var year: Int?
        var bundleId: String?
        var thumb: String?
        var media, pins: Int
        var updated: String
    }

    public func programs() async -> [ProgramSummary] {
        var out: [ProgramSummary] = []
        for p in await store.programs() {
            let media = await store.media(p.slug)
            let pins = await store.state(p.slug).pins.count
            let subject = Treatments.defaultRoles(media)["subject"]
            out.append(ProgramSummary(slug: p.slug, title: p.title, year: p.year, bundleId: p.bundleId,
                                      thumb: subject.map { "/api/programs/\(p.slug)/media/\($0)/thumb" }, media: media.count, pins: pins,
                                      updated: p.updated ?? ""))
        }
        return out
    }

    // MARK: Media files

    func cacheFile(_ parts: String...) -> URL {
        composer.cacheDir.appendingPathComponent(parts.joined(separator: "/"))
    }

    /// A media file variant: image (as stored), thumb (≤256 px PNG), cutout (PNG), mask (PNG).
    public func mediaFile(_ slug: String, _ id: String, _ variant: String) async throws -> (URL, String) {
        guard let rec = await store.mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        switch variant {
        case "image":
            let url = store.mediaFile(slug, rec.file)
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return (url, ext == "jpg" ? "image/jpeg" : "image/\(ext)") }
            let out = cacheFile("media", slug, "\(id).png")
            if !FileManager.default.fileExists(atPath: out.path) { try await assets.image(slug, id).writePNG(to: out) }
            return (out, "image/png")
        case "thumb":
            let out = cacheFile("media", slug, "\(id).thumb.png")
            if !FileManager.default.fileExists(atPath: out.path) {
                let src = store.mediaFile(slug, rec.file)
                if max(rec.width, rec.height) > 256, let t = Bitmap.loadThumbnail(src, maxPixel: 256) {
                    try t.writePNG(to: out)
                } else {
                    let img = try await assets.image(slug, id)
                    let k = min(1, 256 / Double(max(img.width, img.height)))
                    try img.resized(width: Int(Double(img.width) * k), height: Int(Double(img.height) * k), pixel: rec.analysis.pixelArt == true && k >= 1)
                        .writePNG(to: out)
                }
            }
            return (out, "image/png")
        case "cutout":
            let out = cacheFile("media", slug, "\(id).cutout.png")
            if !FileManager.default.fileExists(atPath: out.path) {
                let c = try await assets.cutout(slug, id).bitmap
                let k = min(1, 768 / Double(max(c.width, c.height)))
                try c.resized(width: Int(Double(c.width) * k), height: Int(Double(c.height) * k)).writePNG(to: out)
            }
            return (out, "image/png")
        case "mask":
            return (store.maskFile(slug, id), "image/png")
        default:
            throw IconLabError.notFound(variant)
        }
    }

    public func forgetMediaCache(_ slug: String, _ id: String) async {
        for v in ["png", "thumb.png", "cutout.png"] { try? FileManager.default.removeItem(at: cacheFile("media", slug, "\(id).\(v)")) }
        await assets.forget(slug, id)
    }

    // MARK: Analysis

    /// Queues analysis for every image that hasn't had this revision's.
    /// Fills in `hasAlpha` for pictures analysed before it existed (cheap: a small copy of each).
    public func fillHasAlpha(_ slug: String) async {
        for var m in await store.media(slug) where m.analysis.hasAlpha == nil {
            guard let b = Bitmap.loadThumbnail(store.mediaFile(slug, m.file), maxPixel: 256) else { continue }
            m.analysis.hasAlpha = Analyser.hasAlpha(b)
            do { try await store.upsertMedia(slug, m) } catch { logger.error("Couldn't save \(slug)/\(m.id) with its alpha: \(error)") }
        }
    }

    public func analyseMissing(_ slug: String) async {
        for m in await store.media(slug) where m.analysis.version < Analyser.version {
            await analyse(slug, m.id)
        }
    }

    public func analyse(_ slug: String, _ id: String) async {
        guard let rec = await store.mediaRecord(slug, id) else { return }
        await jobs.enqueue(title: "Analyse · \(rec.name)", program: slug, group: "analysis") { [self] progress in
            let img = try await assets.image(slug, id)
            await progress(0.1, "Vision")
            // a kind you set, or a source's exact label, is never guessed again
            var known: String? = ["you", "source"].contains(rec.kindSource ?? "") ? rec.kind : nil
            var fromSource = false
            if known == nil, let label = rec.sourceLabel ?? rec.remote?.sourceLabel, let k = MediaLabels.exactKind(label) { known = k; fromSource = true }
            var r = Analyser.analyse(img, name: rec.name, knownKind: known, knownCircle: rec.analysis.circle)
            var kind = known ?? "unknown", confidence = known == nil ? 0.0 : 1.0
            var guesses: [KindGuess]?
            if known == nil {
                await progress(0.5, "Classifying")
                let classified: [(kind: String, probability: Double)]?
                do { classified = try await models.classify(img) } catch {
                    logger.notice("Couldn't classify \(slug)/\(id): \(error)")
                    classified = nil
                }
                if let k = classified, let top = k.first {
                    guesses = k.prefix(3).map { KindGuess(kind: $0.kind, p: ($0.probability * 100).rounded() / 100) }
                    let second = k.count > 1 ? k[1].probability : 0
                    // only when sure: at least 70%, and at least twice the next guess
                    if top.probability >= 0.7, top.probability >= second * 2 { kind = top.kind; confidence = top.probability }
                    r.kind = top.kind
                }
            }
            r.suitability = Analyser.suitability(r.analysis, kind: kind == "unknown" ? r.kind : kind, width: img.width, height: img.height)
            // A general search's find: is it about the program? Its words (scored when found) and the picture itself.
            var relevance: (Double, [String])?
            if let words = rec.remote?.relevance {
                var why = words.reasons
                var score = words.text
                let looksLike: Double?
                do { looksLike = try await looksLikeGameMaterial(img) } catch {
                    logger.notice("Couldn't tell whether \(slug)/\(id) looks like game material: \(error)")
                    looksLike = nil
                }
                if let looks = looksLike {
                    score = 0.5 * words.text + 0.5 * looks
                    why.append(looks >= 0.6 ? "looks like game material" : looks <= 0.35 ? "doesn't look like game material" : "could be game material")
                }
                relevance = ((score * 100).rounded() / 100, why)
            }
            await progress(0.7, "Finding parts")
            let title = await store.program(slug)?.title ?? slug
            let found = PartsFinder.find(img, analysis: r, kind: kind, programTitle: title)
            guard var cur = await store.mediaRecord(slug, id) else { return }
            if let mask = r.mask {
                try mask.writePNG(to: store.maskFile(slug, id))
                cur.hasMask = true
            }
            for (pid, m) in found.masks { try m.writePNG(to: assets.partMaskFile(slug, id, pid)) }
            cur.analysis = r.analysis
            cur.kind = kind
            cur.kindConfidence = (confidence * 100).rounded() / 100
            if known == nil { cur.kindSource = kind == "unknown" ? nil : "analysis"; cur.kindGuesses = guesses }
            if fromSource { cur.kindSource = "source"; cur.kindSet = true; cur.sourceLabel = rec.sourceLabel ?? rec.remote?.sourceLabel }
            cur.suitability = r.suitability
            if let (score, why) = relevance { cur.relevance = score; cur.relevanceWhy = why }
            cur.width = img.width; cur.height = img.height
            // you turned it yourself when rotationAuto is false and there's no automatic reason
            if !(cur.rotationAuto == false && cur.rotationWhy == nil) {
                cur.rotation = found.rotation
                cur.rotationAuto = found.rotation != 0 ? true : nil
                cur.rotationWhy = found.rotationWhy
            }
            cur.parts = mergeParts(old: cur.allParts, found: found.parts, kind: kind, rec: cur)
            cur.picked = cur.anyPicked
            try await store.upsertMedia(slug, cur)
            await forgetMediaCache(slug, id)
            cur = await sizeParts(slug, cur)
            if cur.hasMask, let c = try? await assets.cutout(slug, id) { cur.cutoutSize = [c.bitmap.width, c.bitmap.height] }
            try await store.upsertMedia(slug, cur)
            await broadcastMedia(slug, cur)
        }
    }

    // MARK: Rendering

    public struct RenderedRef: Codable, Sendable {
        var url: String
        var width: Int
        var height: Int
        var box: [Double]
    }

    public func renderContent(program: String, content: Content, pixelWidth: Int, canvasWidth: Double, transform: Transform? = nil) async throws -> RenderedRef {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        // the layer's place only matters to a mask locked to the canvas
        var placeKey = ""
        if case .image(let ic) = content, ic.effects.contains(where: { $0.on && $0.op == "mask" && $0.t.string("lock", "canvas") == "canvas" }), let t = transform {
            placeKey = String(data: (try? e.encode(t)) ?? Data(), encoding: .utf8) ?? ""
        }
        let stamp = await assetStamp(program, content)
        let key = Store.sha256(try e.encode(content) + Data("\(program)|\(pixelWidth)|\(canvasWidth)|\(IconComposer.revision)|\(stamp)|\(placeKey)".utf8))
        let png = cacheFile("content", "\(key.prefix(24)).png"), meta = cacheFile("content", "\(key.prefix(24)).json")
        if let d = try? Data(contentsOf: meta), let r = try? JSONDecoder().decode(RenderedRef.self, from: d),
           FileManager.default.fileExists(atPath: png.path) { return r }
        let r = try await renderer.content(content, program: program, pixelWidth: pixelWidth, canvasWidth: canvasWidth, transform: transform)
        try r.bitmap.writePNG(to: png)
        let ref = RenderedRef(url: "/api/cache/content/\(key.prefix(24)).png", width: r.bitmap.width, height: r.bitmap.height, box: r.box)
        try JSONEncoder().encode(ref).write(to: meta)
        return ref
    }

    /// Changes when an asset's mask or file changes, so cached renders of it go stale.
    func assetStamp(_ program: String, _ content: Content) async -> String {
        guard case .image(let ic) = content else { return "" }
        return await stamp(program, ic.asset)
    }

    func stamp(_ program: String, _ asset: String) async -> String {
        let fm = FileManager.default
        if let ref = AssetRef(asset), ref.part != nil || ref.upscale != nil, let rec = await store.mediaRecord(program, ref.media),
           let p = rec.allParts.first(where: { $0.id == (ref.part ?? "whole") }) {
            let v = Store.sha256(Data((try? JSONEncoder().encode(PartVersion(p, rec))) ?? Data()))
            let up = fm.fileExists(atPath: assets.upscaledFile(program, ref).path) ? "up" : ""
            return "\(asset):\(v):\(up)"
        }
        let mask = (try? fm.attributesOfItem(atPath: store.maskFile(program, asset).path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(asset):\(mask)"
    }

    public func renderShape(_ shape: Shape, size: Int) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let key = Store.sha256(try e.encode(shape) + Data("\(size)|\(IconComposer.revision)".utf8)).prefix(24)
        let png = cacheFile("shape", "\(key).png")
        if !FileManager.default.fileExists(atPath: png.path) { try Shapes.render(shape, size: max(16, min(2048, size))).writePNG(to: png) }
        return "/api/cache/shape/\(key).png"
    }

    public func renderMask(program: String, mask: Mask, size: Int) async throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let assetStamp = mask.kind == "image" ? await stamp(program, mask.t.string("asset")) : ""
        let key = Store.sha256(try e.encode(mask) + Data("\(program)|\(size)|\(IconComposer.revision)|\(assetStamp)".utf8)).prefix(24)
        let png = cacheFile("mask", "\(key).png")
        if !FileManager.default.fileExists(atPath: png.path) {
            try await renderer.mask(mask, program: program, size: max(16, min(2048, size))).writePNG(to: png)
        }
        return "/api/cache/mask/\(key).png"
    }

    public func renderIcon(_ doc: Doc, appearance: String, size: Int) async throws -> (url: String, icon: String) {
        let (png, icon) = try await composer.render(doc, appearance: appearance, size: size)
        let rel = png.path.replacingOccurrences(of: composer.cacheDir.path + "/", with: "")
        let relIcon = icon.path.replacingOccurrences(of: composer.cacheDir.path + "/", with: "")
        return ("/api/cache/\(rel)", relIcon)
    }

    // MARK: Saving

    public func save(_ slug: String, ids: [String]) async throws -> [[String: String]] {
        var out: [[String: String]] = []
        let dir = store.dir(slug).appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for id in ids {
            guard let data = await store.doc(slug, id) else { continue }
            let doc = try JSONDecoder().decode(Doc.self, from: data)
            let (png, icon) = try await composer.render(doc, appearance: "light", size: 1024)
            let name = "\(Store.slugify(doc.name))-\(id.prefix(6))"
            let iconDest = dir.appendingPathComponent("\(name).icon"), pngDest = dir.appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(at: iconDest)
            try? FileManager.default.removeItem(at: pngDest)
            try FileManager.default.copyItem(at: icon, to: iconDest)
            try FileManager.default.copyItem(at: png, to: pngDest)
            try data.write(to: dir.appendingPathComponent("\(name).json"))
            out.append(["id": id, "icon": iconDest.path, "png": pngDest.path])
        }
        return out
    }

    /// 0…1: how much the picture looks like game material (box art, a screenshot, a logo, a disc) rather than the
    /// things that share game names (photos, paintings, old books), by MobileCLIP.
    func looksLikeGameMaterial(_ img: Bitmap) async throws -> Double {
        let e = try await models.imageEmbedding(img)
        let game = try await models.textEmbeddings(Relevance.gamePrompts), other = try await models.textEmbeddings(Relevance.otherPrompts)
        func sim(_ t: [Float]) -> Double { Double(zip(e, t).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
        // a softmax over all prompts at CLIP's temperature; the game prompts' share
        let logits = (game + other).map { 100 * sim($0) }
        let mx = logits.max() ?? 0
        let ex = logits.map { exp($0 - mx) }
        let total = ex.reduce(0, +)
        return ex.prefix(game.count).reduce(0, +) / max(1e-9, total)
    }
}
