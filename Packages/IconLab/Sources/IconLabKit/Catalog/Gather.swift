import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Catalog")

// Stage 2's online gathering: a job per media source finds the program's pictures there, downloads a small copy of
// each (the source's thumbnail, else the image itself up to 20 MB), adds it with where it came from, and queues the
// cheap analysis. When every source is done, copies of the same art from several sources are marked as duplicates of
// the best one.

nonisolated extension Catalog {
    /// Sources whose labels say for certain what a picture is (box front, disc, logo…); the analysis keeps their kind.
    static let trustedLabels: Set<String> = ["launchbox", "screenscraper", "steamgriddb", "igdb", "steam", "gog", "wikidata", "thegamesdb",
                                             "lutris", "pcgamingwiki"]

    /// Queues a gathering job per ready media source (Brave only when asked: it's paid per search). Returns the jobs' ids.
    /// `only`: just these sources (ids), each run even if it's Brave. `clear`: first remove what they found before.
    public func gather(_ slug: String, brave: Bool = false, only: [String]? = nil, clear: Bool = false) async throws -> [String] {
        guard let identity = await identity(slug) else { throw IconLabError.notFound("program \(slug)") }
        if let only, only.contains("files") {
            _ = try await lab.rescanFiles(slug, clear: clear)
            if only == ["files"] { return [] }
        }
        if clear, let only { try await lab.removeMedia(slug) { m in m.remote.map { only.contains($0.source) } ?? false } }
        var chosen: [(any MediaSource, SourceInfo)] = []
        for s in mediaSources {
            let i = await s.info
            if let only { guard i.state == .ready, only.contains(i.id) else { continue } } else {
                guard i.state == .ready, i.id != "brave" || brave else { continue }
            }
            chosen.append((s, i))
        }
        let run = GatherRun(left: chosen.count)
        var ids: [String] = []
        for (s, i) in chosen {
            let id = await lab.jobs.enqueue(title: "Gather · \(i.name)", program: slug, group: "gather", source: i.id) { [self] progress in
                do {
                    try await self.gatherOne(slug, identity, s, i, progress)
                } catch {
                    if await run.finish() { await self.markDuplicatesJob(slug) }
                    throw error
                }
                if await run.finish() { await self.markDuplicatesJob(slug) }
            }
            ids.append(id)
        }
        return ids
    }

    func gatherOne(_ slug: String, _ identity: ProgramIdentity, _ source: any MediaSource, _ info: SourceInfo,
                   _ progress: @escaping @Sendable (Double, String?) async -> Void) async throws {
        await progress(0.02, "Looking up \(identity.title)")
        let found = try await withTimeout(240) { try await source.media(for: identity) }
        var have = Set<String>()
        for m in await lab.store.media(slug) {
            if let r = m.remote { have.insert(r.url); if let t = r.thumbUrl { have.insert(t) } }
        }
        // pictures already here get the source's newer word scores (relevance), and are analysed again for them
        for m in found where have.contains(m.url) && m.relevance != nil {
            guard var rec = await lab.store.media(slug).first(where: { $0.remote?.url == m.url }), rec.remote?.relevance != m.relevance else { continue }
            rec.remote?.relevance = m.relevance
            do { try await lab.store.upsertMedia(slug, rec) } catch { logger.error("Couldn't save \(slug)/\(rec.id)'s word scores: \(error)") }
            await lab.analyse(slug, rec.id)
        }
        var seen = Set<String>()
        let todo = found.filter { !have.contains($0.url) && seen.insert($0.url).inserted }
        if todo.isEmpty { await progress(1, found.isEmpty ? "Nothing found" : "Nothing new"); return }
        var added = 0, failed = 0
        for (n, m) in todo.enumerated() {
            await progress(0.05 + 0.95 * Double(n) / Double(todo.count), "Downloading \(n + 1) of \(todo.count)")
            do {
                if try await addRemote(slug, m, sourceName: info.name) { added += 1 } else { failed += 1 }
            } catch { failed += 1 }
        }
        await progress(1, "\(added) added" + (failed > 0 ? ", \(failed) unavailable" : ""))
    }

    /// Downloads one picture's small copy and adds it to the program. False when it wasn't a picture.
    func addRemote(_ slug: String, _ m: RemoteMedia, sourceName: String) async throws -> Bool {
        var m = m
        let small = m.thumbUrl ?? m.url
        guard var url = URL(string: small) else { return false }
        if m.source == "screenscraper" { url = await screenScraper.authorise(url) }
        let r = try await ctx.http.fetch(url, cache: .none, maxBytes: 20_000_000, timeout: 90)
        guard r.data.count > 100 else { return false }
        let ext = Self.imageExtension(r.contentType, url: url)
        guard let ext else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-gather-\(UUID().uuidString).\(ext)")
        try r.data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let bmp = Bitmap.load(tmp), bmp.width >= 16, bmp.height >= 16 else { return false }
        if m.thumbUrl == nil, m.width == nil { m.width = bmp.width; m.height = bmp.height }   // we have the full copy
        let label = m.title ?? m.sourceLabel ?? "image"
        let name = "\(label)\(m.region.map { " (\($0))" } ?? "").\(ext)".replacingOccurrences(of: "/", with: "-")
        var rec = try await lab.store.addMedia(slug, from: tmp, name: name, source: sourceName, sourceUrl: m.pageUrl,
                                               provenance: m.sourceLabel.map { "\(sourceName) › \($0)" }, kind: m.kind)
        rec.remote = m
        rec.sourceLabel = m.sourceLabel
        // a source's label sets the kind only when it names one exactly; otherwise the analysis decides
        if let label = m.sourceLabel, let k = MediaLabels.exactKind(label) {
            rec.kind = k
            rec.kindConfidence = 0.95
            rec.kindSource = "source"
            rec.kindSet = true
        } else {
            rec.kind = "unknown"
        }
        try await lab.store.upsertMedia(slug, rec)
        await broadcast(slug, rec)
        await lab.analyse(slug, rec.id)
        return true
    }

    static func imageExtension(_ contentType: String?, url: URL) -> String? {
        let ct = (contentType ?? "").lowercased()
        if ct.contains("jpeg") || ct.contains("jpg") { return "jpg" }
        if ct.contains("png") { return "png" }
        if ct.contains("gif") { return "gif" }
        if ct.contains("webp") { return "webp" }
        if ct.contains("bmp") { return "bmp" }
        if ct.contains("html") || ct.contains("json") || ct.contains("text/") { return nil }
        let e = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains(e) { return e == "jpeg" ? "jpg" : e }
        return "jpg"
    }

    func broadcast(_ slug: String, _ rec: MediaRecord) async {
        if let data = try? JSONEncoder().encode(lab.dto(slug, rec)), let obj = try? JSONSerialization.jsonObject(with: data) {
            await lab.jobs.broadcast(["type": "media", "program": slug, "media": obj])
        }
    }

    // MARK: Duplicates

    static let sourceRank = ["launchbox", "screenscraper", "igdb", "steamgriddb", "thegamesdb", "gog", "steam", "pcgamingwiki", "wikipedia",
                             "wikidata", "commons", "lutris", "internetarchive", "macintoshrepository", "myabandonware", "winworld", "openverse", "brave"]

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
        return dot / max(1e-9, (na * nb).squareRoot())
    }

    func markDuplicatesJob(_ slug: String) async {
        await lab.jobs.enqueue(title: "Find duplicate pictures", program: slug, group: "gather") { [self] progress in
            await progress(0.1, nil)
            try await self.markDuplicates(slug)
        }
    }

    /// Same art from several sources (a perceptual match on the small copies): all but the best copy — the largest the
    /// source offers, then the best source — point at it with `duplicateOf`.
    public func markDuplicates(_ slug: String) async throws {
        // every picture: gathered, imported and from your files (the same art can arrive more than one way)
        let all = await lab.store.media(slug).filter { $0.derivedFrom == nil }
        func area(_ m: MediaRecord) -> Int { (m.remote?.width ?? m.width) * (m.remote?.height ?? m.height) }
        func rank(_ m: MediaRecord) -> Int { Self.sourceRank.firstIndex(of: m.remote?.source ?? "") ?? 99 }
        // Each picture with its plain borders (letterboxing, pillarboxing, scan margins) trimmed first: shared black
        // bars around different screenshots would otherwise make them hash alike.
        struct Feat { let m: MediaRecord; let hash: UInt64; let aspect: Double; let image: Bitmap }
        var feats: [Feat] = []
        for m in all {
            guard var b = Bitmap.loadThumbnail(lab.store.mediaFile(slug, m.file), maxPixel: 384) else { continue }
            if let t = Deep.trimBox(b), t.w > 16, t.h > 16 { b = b.cropped(x: t.x, y: t.y, width: t.w, height: t.h) }
            let h = DHash.hash(b)
            guard h != 0, h != UInt64.max else { continue }   // flat pictures all hash alike
            feats.append(Feat(m: m, hash: h, aspect: Double(b.width) / Double(max(1, b.height)), image: b))
        }
        // Best copies first, and a picture joins a group only by matching that group's best copy itself (no chains:
        // A like B and B like C doesn't make A like C). A hash match is only a candidate; MobileCLIP's embedding
        // must agree it's the same art (0.95 cosine: same art from two sources measured 0.987, different discs of
        // one game 0.91–0.93).
        feats.sort { area($0.m) != area($1.m) ? area($0.m) > area($1.m) : rank($0.m) < rank($1.m) }
        var embeddings: [String: [Float]] = [:]
        var groupsList: [(best: Feat, members: [MediaRecord])] = []
        // identical files are the same picture, whatever they look like at 9×8
        var fileHash: [String: String] = [:]
        for f in feats { fileHash[f.m.id] = (try? Data(contentsOf: lab.store.mediaFile(slug, f.m.file))).map { Store.sha256($0) } }
        for f in feats {
            var placed = false
            for gi in groupsList.indices {
                let b = groupsList[gi].best
                if let a = fileHash[f.m.id], a == fileHash[b.m.id] { groupsList[gi].members.append(f.m); placed = true; break }
                guard DHash.same((f.hash, f.aspect), (b.hash, b.aspect)) else { continue }
                if embeddings[f.m.id] == nil, let e = try? await lab.models.imageEmbedding(f.image) { embeddings[f.m.id] = e }
                if embeddings[b.m.id] == nil, let e = try? await lab.models.imageEmbedding(b.image) { embeddings[b.m.id] = e }
                if let ea = embeddings[f.m.id], let eb = embeddings[b.m.id] {
                    guard Self.cosine(ea, eb) >= 0.95 else { continue }
                } else if DHash.distance(f.hash, b.hash) > 3 {
                    continue   // no model to confirm: only near-identical hashes count
                }
                groupsList[gi].members.append(f.m)
                placed = true
                break
            }
            if !placed { groupsList.append((f, [f.m])) }
        }
        var groups: [Int: [MediaRecord]] = [:]
        for (i, g) in groupsList.enumerated() { groups[i] = g.members }
        var changed: [MediaRecord] = []
        let grouped = Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        for g in groups.values {
            guard let best = g.first else { continue }   // the group's best copy came first
            for var m in g {
                let want: String? = g.count > 1 && m.id != best.id ? best.id : nil
                if m.duplicateOf != want { m.duplicateOf = want; changed.append(m) }
            }
        }
        // pictures that no longer match anything lose an old mark
        for var m in all where m.duplicateOf != nil && !grouped.contains(m.id) { m.duplicateOf = nil; changed.append(m) }
        for m in changed {
            guard var cur = await lab.store.mediaRecord(slug, m.id) else { continue }
            cur.duplicateOf = m.duplicateOf
            try await lab.store.upsertMedia(slug, cur)
            await broadcast(slug, cur)
        }
    }
}

actor GatherRun {
    var left: Int
    init(left: Int) { self.left = left }
    /// True for the last one to finish.
    func finish() -> Bool { left -= 1; return left == 0 }
}
