import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Lab")

nonisolated extension Lab {
    /// Picks or unpicks an image. Picking one that came from online queues its hi-res download and the deep
    /// analysis; picking a local one queues just the deep analysis.
    public func pick(_ slug: String, _ id: String, _ picked: Bool) async throws -> MediaRecord {
        return try await pickAll(slug, id, picked)
    }

    func pickOld(_ slug: String, _ id: String, _ picked: Bool) async throws -> MediaRecord {
        guard var rec = await store.mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        rec.picked = picked
        if picked, rec.hires == nil || rec.hires == "failed" {
            rec.hires = "queued"
            try await store.upsertMedia(slug, rec)
            await deepen(slug, id)
        } else {
            try await store.upsertMedia(slug, rec)
        }
        return rec
    }

    /// Removes media (their files, masks, frames and part masks) and tells the UI: `{ type: "media-removed", program, ids }`.
    public func removeMedia(_ slug: String, where match: (MediaRecord) -> Bool) async throws {
        let all = await store.media(slug)
        let gone = all.filter(match)
        guard !gone.isEmpty else { return }
        let fm = FileManager.default
        let masks = store.dir(slug).appendingPathComponent("masks")
        let maskFiles = (try? fm.contentsOfDirectory(atPath: masks.path)) ?? []
        for m in gone {
            try? fm.removeItem(at: store.mediaFile(slug, m.file))
            for p in m.allParts { if let f = p.file { try? fm.removeItem(at: store.mediaFile(slug, f)) } }
            for f in maskFiles where f == "\(m.id).png" || f.hasPrefix("\(m.id).") { try? fm.removeItem(at: masks.appendingPathComponent(f)) }
            await assets.forget(slug, m.id)
        }
        let ids = Set(gone.map(\.id))
        try await store.saveMedia(slug, all.filter { !ids.contains($0.id) })
        await jobs.broadcast(["type": "media-removed", "program": slug, "ids": ids.sorted()])
    }

    func broadcastMedia(_ slug: String, _ rec: MediaRecord) async {
        if let data = try? JSONEncoder().encode(dto(slug, rec)), let obj = try? JSONSerialization.jsonObject(with: data) {
            await jobs.broadcast(["type": "media", "program": slug, "media": obj])
        }
    }

    /// The hi-res download (when the image came from online and a larger copy exists) and the deep analysis.
    public func deepen(_ slug: String, _ id: String) async {
        guard let rec = await store.mediaRecord(slug, id) else { return }
        let title = await store.program(slug)?.title ?? slug
        await jobs.enqueue(title: "Hi-res and analysis · \(rec.name)", program: slug, group: "hires") { [self] progress in
            await self.setHires(slug, id, "running")
            do {
                guard var cur = await store.mediaRecord(slug, id) else { return }
                if let remote = cur.remote, let url = URL(string: remote.url), needsDownload(cur) {
                    await progress(0.1, "Downloading \(url.host ?? "")")
                    // through the catalogue's fetcher when there is one: one per-host limit for everything (archive.org's
                    // 4 s), and ScreenScraper's URLs get their credentials back
                    let data: Data
                    if let cat = Catalog.shared, let u = await cat.downloadURL(remote) {
                        data = try await cat.ctx.http.fetch(u, cache: .none, maxBytes: 60_000_000, timeout: 120).data
                    } else {
                        data = try await downloader.data(url)
                    }
                    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-\(UUID().uuidString).\(ext)")
                    try data.write(to: tmp)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    guard let big = Bitmap.load(tmp) else { throw IconLabError.tool("the source's copy isn't a picture") }
                    if big.width * big.height <= cur.width * cur.height {
                        // what we have is already the largest: say so (no download next time) and analyse it as it is
                        cur.remote?.width = big.width; cur.remote?.height = big.height
                        try await store.upsertMedia(slug, cur)
                    } else {
                    try await store.replaceMediaFile(slug, id, with: tmp)
                    // the store renamed the file (its type may have changed): carry on from its record, not the old one
                    if let fresh = await store.mediaRecord(slug, id) { cur.file = fresh.file }
                    cur.width = big.width; cur.height = big.height
                    cur.upgraded = true
                    try await store.upsertMedia(slug, cur)
                    await forgetMediaCache(slug, id)
                    await progress(0.4, "Analysing the larger copy")
                    // the cheap tier again, on the big copy (a better mask)
                    let r = Analyser.analyse(big, name: cur.name, knownKind: cur.kindSet == true ? cur.kind : nil, knownCircle: cur.analysis.circle)
                    if let m = r.mask { try m.writePNG(to: store.maskFile(slug, id)); cur.hasMask = true }
                    cur.analysis = r.analysis; cur.kind = r.kind; cur.kindConfidence = r.kindConfidence; cur.suitability = r.suitability
                    try await store.upsertMedia(slug, cur)
                    await forgetMediaCache(slug, id)
                    }
                }
                await progress(0.5, "Second-opinion cut-out")
                let img = try await assets.image(slug, id)
                // BiRefNet's mask: kept beside Vision's, and used instead when Vision found no subject or one
                // that's nearly all or nothing of the picture
                if let bm = try? await models.subjectMask(img) {
                    try? bm.writePNG(to: store.dir(slug).appendingPathComponent("masks/\(id)-birefnet.png"))
                    if !cur.hasMask || cur.analysis.coverage < 0.05 || cur.analysis.coverage > 0.92 {
                        try bm.writePNG(to: store.maskFile(slug, id))
                        cur.hasMask = true
                        cur.deep = (cur.deep ?? [:]).merging(["mask": "birefnet"]) { _, b in b }
                        await forgetMediaCache(slug, id)
                        if let c = try? await assets.cutout(slug, id) { cur.cutoutSize = [c.bitmap.width, c.bitmap.height] }
                    }
                }
                await progress(0.6, "Deep analysis")
                let cut = cur.hasMask ? try? await assets.cutout(slug, id).bitmap : nil
                let deep = Deep.analyse(img, cutout: cut, record: cur, programTitle: title)
                cur.deep = (cur.deep ?? [:]).merging(deep.findings) { _, b in b }
                cur.hires = "done"
                try await store.upsertMedia(slug, cur)
                await broadcastMedia(slug, cur)
                await progress(0.85, "Adding what it found")
                // parts replaced the derived copies (straightened, title) and upscaling moved to the design stage
            } catch {
                await self.setHires(slug, id, "failed")
                throw error
            }
        }
    }

    func needsDownload(_ m: MediaRecord) -> Bool {
        guard let r = m.remote else { return false }
        if let w = r.width, let h = r.height { return w * h > m.width * m.height }
        return m.remote?.url != m.remote?.thumbUrl
    }

    func setHires(_ slug: String, _ id: String, _ state: String) async {
        guard var cur = await store.mediaRecord(slug, id) else { return }
        cur.hires = state
        do { try await store.upsertMedia(slug, cur) } catch { logger.error("Couldn't save \(slug)/\(id)'s hi-res state: \(error)") }
        await broadcastMedia(slug, cur)
    }

    /// A derived image (straightened, trimmed, the title) added as media of its own and analysed.
    func addDerived(_ slug: String, _ d: Deep.Derived, from parent: MediaRecord) async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try d.bitmap.writePNG(to: tmp)
            var rec = try await store.addMedia(slug, from: tmp, name: d.name + ".png", source: parent.source, sourceUrl: parent.sourceUrl,
                                               provenance: "\(parent.provenance.map { $0 + " › " } ?? "")\(d.why)", kind: d.kind)
            rec.derivedFrom = parent.id
            rec.kindSet = true
            rec.kindConfidence = 0.9
            try await store.upsertMedia(slug, rec)
            await broadcastMedia(slug, rec)
            await analyse(slug, rec.id)
        } catch {
            return
        }
    }

    // MARK: Files on this Mac

    public struct FSEntry: Codable, Sendable {
        var name: String
        var path: String
        var dir: Bool
        var size: Int?
        var type: String          // wrapp, app, disc-image, installer, archive, program, image, folder, other
        var hint: String?
    }

    public struct FSListing: Codable, Sendable {
        var path: String
        var parent: String?
        var entries: [FSEntry]
        var places: [FSEntry]
    }

    public func listFiles(_ path: String?, showHidden: Bool) -> FSListing {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let p = ((path?.isEmpty ?? true) ? home : path ?? home) as NSString
        let url = URL(fileURLWithPath: p.expandingTildeInPath).standardizedFileURL
        var entries: [FSEntry] = []
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        for n in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where showHidden || !n.hasPrefix(".") {
            let u = url.appendingPathComponent(n)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: u.path, isDirectory: &isDir)
            let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil
            let (type, hint) = FileKinds.identify(u, isDir: isDir.boolValue)
            entries.append(FSEntry(name: n, path: u.path, dir: isDir.boolValue, size: isDir.boolValue ? nil : size, type: type, hint: hint))
        }
        var places: [FSEntry] = [FSEntry(name: "Home", path: home, dir: true, type: "folder")]
        for (name, path) in [("Built game apps", tools.builtApps?.path ?? ""),
                             ("Installers store", "/Users/Shared/second-chance/installers"),
                             ("Downloads", home + "/Downloads"), ("Applications", "/Applications"), ("Volumes", "/Volumes")]
        where fm.fileExists(atPath: path) {
            places.append(FSEntry(name: name, path: path, dir: true, type: "folder"))
        }
        let parent = url.path == "/" ? nil : url.deletingLastPathComponent().path
        return FSListing(path: url.path, parent: parent, entries: entries, places: places)
    }
}

/// What a file is, quickly (by name and its first bytes), for the file browser.
nonisolated public enum FileKinds {
    public static func identify(_ u: URL, isDir: Bool) -> (String, String?) {
        let ext = u.pathExtension.lowercased()
        let fm = FileManager.default
        if isDir {
            if ext == "app" {
                if fm.fileExists(atPath: u.appendingPathComponent("Contents/SharedSupport/prefix").path)
                    || fm.fileExists(atPath: u.appendingPathComponent("Contents/Resources/AppSettings.plist").path) {
                    return ("wrapp", "A game's app made by Second Chance")
                }
                return ("app", "A Mac app")
            }
            let lower = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).map { $0.lowercased() }
            if lower.contains(where: { $0.hasSuffix(".exe") }) { return ("folder", "Has Windows programs") }
            return ("folder", nil)
        }
        switch ext {
        case "iso", "bin", "cue", "img", "toast", "mdf", "nrg", "dmg", "cdr", "dsk", "image", "hfs", "hfv":
            return ("disc-image", nil)
        case "exe", "msi":
            let head = (try? FileHandle(forReadingFrom: u)).flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 4096) } ?? Data()
            if ext == "msi" { return ("installer", "Windows Installer package") }
            let s = String(decoding: head, as: UTF8.self).lowercased()
            if u.lastPathComponent.lowercased().contains("setup") || u.lastPathComponent.lowercased().contains("install") || s.contains("inno") {
                return ("installer", nil)
            }
            return ("program", "Windows program")
        case "zip", "7z", "rar", "lha", "lzh", "arj", "cab", "sit", "sea", "hqx", "cpt", "tar", "gz", "bz2", "xz":
            return ("archive", nil)
        case "png", "jpg", "jpeg", "gif", "bmp", "ico", "icns", "pcx", "tga", "tif", "tiff", "webp", "pict", "pct":
            return ("image", nil)
        default:
            return ("other", nil)
        }
    }
}
