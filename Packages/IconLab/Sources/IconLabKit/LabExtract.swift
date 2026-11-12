import Foundation
import Logging
import ProgramImages

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Extract")

/// "Add from files": finds every image in a path with `ProgramImages` (WrappKit, docs/program-images.md), in this
/// process and off the main actor, streams its progress to the page as `scan` events, and adds the images it found
/// as media. Cancelling the scan's job stops the crawl.
nonisolated extension Lab {
    /// Starts a scan; returns its id. Events: `{type:"scan", program, scan, event: <an extraction event's JSON line>}`.
    public func extract(_ slug: String, path: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { throw IconLabError.notFound(path) }
        let scan = UUID().uuidString.lowercased().prefix(8)
        let out = store.dir(slug).appendingPathComponent("scans").appendingPathComponent(String(scan))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // what was scanned, so "Your files" can be cleared and scanned again
        try Store.json(Scan(scan: String(scan), path: path, at: ISO8601DateFormatter().string(from: Date()))).write(to: out.appendingPathComponent("scan.json"))
        let name = (path as NSString).lastPathComponent
        await jobs.enqueue(title: "Find images in \(name)", program: slug, group: "scan", source: "files") { [self] progress in
            var seen = 0
            let (lines, sink) = AsyncStream<String>.makeStream()
            let crawl = Task {
                defer { sink.finish() }
                _ = try await ProgramImageExtractor.extract(URL(fileURLWithPath: path), options: ExtractionOptions(outputDirectory: out)) {
                    sink.yield($0.jsonLine)
                }
            }
            defer { crawl.cancel() }
            for await line in lines {
                guard let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let ev = try? JSONSerialization.data(withJSONObject: ["type": "scan", "program": slug, "scan": String(scan), "event": obj]) {
                    await self.jobs.broadcastData(ev)
                }
                if obj["event"] as? String == "progress", let nodes = obj["nodes"] as? Double, let queued = obj["queued"] as? Double {
                    let images = obj["images"] as? Int ?? seen
                    await progress(min(0.9, nodes / max(1, nodes + queued)), "\(Int(nodes)) files looked at, \(images) images")
                }
                if obj["event"] as? String == "image" { seen += 1 }
            }
            try await withTaskCancellationHandler { try await crawl.value } onCancel: { crawl.cancel() }
            await progress(0.92, "Adding the images")
            try await self.importExtracted(slug, from: out, scanRoot: name)
        }
        return String(scan)
    }

    public struct Scan: Codable, Sendable { public var scan: String; public var path: String; public var at: String }   // at: ISO 8601

    /// Every scan of the program that recorded its path, newest first.
    public func scans(_ slug: String) -> [Scan] {
        let dir = store.dir(slug).appendingPathComponent("scans")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.compactMap { id in
            (try? Data(contentsOf: dir.appendingPathComponent(id).appendingPathComponent("scan.json"))).flatMap { try? JSONDecoder().decode(Scan.self, from: $0) }
        }.sorted { $0.at > $1.at }
    }

    /// "Your files", cleared and gathered again: removes every picture from them, forgets the old scans, and scans
    /// each path scanned before (that's still there) again. Returns the scans started.
    public func rescanFiles(_ slug: String, clear: Bool) async throws -> [String] {
        var paths: [String] = []
        for s in scans(slug) where !paths.contains(s.path) && FileManager.default.fileExists(atPath: s.path) { paths.append(s.path) }
        if clear {
            try await removeMedia(slug) { $0.source == "Your files" }
            try? FileManager.default.removeItem(at: store.dir(slug).appendingPathComponent("scans"))
        }
        var started: [String] = []
        for p in paths { started.append(try await extract(slug, path: p)) }
        return started
    }

    /// Reads `records.jsonl` and adds each image (the best of each family) as media from "Your files".
    func importExtracted(_ slug: String, from dir: URL, scanRoot: String) async throws {
        let recordsFile = dir.appendingPathComponent("records.jsonl")
        guard let text = try? String(contentsOf: recordsFile, encoding: .utf8) else { return }
        var records: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { records.append(o) }
        }
        // One per family (its representative), the best first; skip what the extractor says isn't art.
        let skipRoles: Set<String> = ["runtime-library", "ui-like-name", "cursor"]
        let iconRoles: Set<String> = ["main-program-icon", "likely-main-program-icon", "shortcut-icon", "autorun-icon", "volume-icon",
                                      "msi-icon", "mac-app-icon", "custom-icon", "first-icon-group", "icon", "app-bundle-icon"]
        let reps = records.filter { ($0["isFamilyRepresentative"] as? Bool) ?? true }
            .sorted { (($0["score"] as? Double) ?? 0) > (($1["score"] as? Double) ?? 0) }
        // A video's frames come in as one picture (its best frame) with the others as its parts.
        var movies: [String: [[String: Any]]] = [:], movieOrder: [String] = []
        func movieKey(_ r: [String: Any]) -> String? {
            let p = Lab.provenanceString(r)
            guard let range = p.range(of: " › frame-") else { return nil }
            return String(p[..<range.lowerBound])
        }
        for r in reps {
            guard let k = movieKey(r) else { continue }
            if movies[k] == nil { movieOrder.append(k) }
            movies[k, default: []].append(r)
        }
        for k in movieOrder {
            guard let frames = movies[k], !frames.isEmpty else { continue }
            try await importMovie(slug, dir: dir, movie: k, frames: frames)
        }
        let movieShas = Set(movies.values.flatMap { $0 }.compactMap { $0["sha256"] as? String })
        var added = 0
        for r in reps where !movieShas.contains((r["sha256"] as? String) ?? "") {
            guard let sha = r["sha256"] as? String else { continue }
            let roles = Set((r["roles"] as? [String]) ?? [])
            let score = (r["score"] as? Double) ?? 0
            let isIcon = !roles.isDisjoint(with: iconRoles)
            // runtime files (a system's, an engine's) never come in, icon or not
            if roles.contains("runtime-library") { continue }
            if !roles.isDisjoint(with: skipRoles) && !isIcon { continue }
            if score < 15 && !isIcon { continue }
            if added >= 150 { break }   // the rest stay in the scan's folder
            let file = (r["file"] as? String).map { dir.appendingPathComponent($0) } ?? dir.appendingPathComponent("\(sha).png")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let w = (r["width"] as? Int) ?? 0, h = (r["height"] as? Int) ?? 0
            if max(w, h) < 16 || Double(max(w, h)) / Double(max(1, min(w, h))) > 8 { continue }
            let provenance = Lab.provenanceString(r)
            let parts = provenance.components(separatedBy: " › ")
            let shortName = parts.count >= 2 ? parts[parts.count - 2] : (parts.last ?? sha)
            let kind: String? = isIcon ? "icon" : (roles.contains("installer-art") ? "art" : (roles.contains("video-frame") ? "title-screen" : nil))
            var rec = try await store.addMedia(slug, from: file, name: "\(shortName).png", source: "Your files", provenance: provenance, kind: kind)
            rec.suitability = min(5, max(rec.suitability, score / 20))
            if kind != nil { rec.kindSet = true; rec.kindConfidence = 0.8 }
            if roles.contains("main-program-icon") || roles.contains("likely-main-program-icon") { rec.picked = true }
            var extra: [String: JSONValue] = ["roles": .array(roles.sorted().map { .string($0) }), "extractScore": .number(score)]
            if let reasons = r["scoreReasons"] as? [String] { extra["scoreReasons"] = .array(reasons.map { .string($0) }) }
            if let n = r["sources"] as? Int { extra["foundIn"] = .number(Double(n)) }
            rec.deep = (rec.deep ?? [:]).merging(extra) { _, b in b }
            try await store.upsertMedia(slug, rec)
            await broadcastMedia(slug, rec)
            await analyse(slug, rec.id)
            added += 1
        }
    }

    /// One picture for a video: its best-ranked frame, with every frame as a part (in time order).
    func importMovie(_ slug: String, dir: URL, movie: String, frames: [[String: Any]]) async throws {
        func frameNumber(_ r: [String: Any]) -> Int {
            let p = Lab.provenanceString(r)
            guard let range = p.range(of: " › frame-") else { return 0 }
            return Int(p[range.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        let ordered = frames.sorted { frameNumber($0) < frameNumber($1) }
        guard let poster = ordered.max(by: { (($0["score"] as? Double) ?? 0) < (($1["score"] as? Double) ?? 0) }),
              let posterSha = poster["sha256"] as? String else { return }
        let posterFile = dir.appendingPathComponent((poster["file"] as? String) ?? "\(posterSha).png")
        let name = ((movie.components(separatedBy: " › ").last ?? "Video") as NSString).lastPathComponent
        var rec = try await store.addMedia(slug, from: posterFile, name: name, source: "Your files", provenance: movie, kind: "title-screen")
        rec.kindSet = true
        rec.kindConfidence = 0.7
        let score = (poster["score"] as? Double) ?? 0
        rec.deep = (rec.deep ?? [:]).merging(["extractScore": .number(score), "roles": .array([.string("video-frame")]),
                                              "frames": .number(Double(ordered.count))]) { _, b in b }
        var parts = rec.allParts
        if let i = parts.firstIndex(where: { $0.id == "whole" }) { parts[i].name = "Frame \(frameNumber(poster)) (best)" }
        rec.deep?["bestFrame"] = .string("frame-\(frameNumber(poster))")
        // every frame, the best one too, is a frame part; the whole (the best frame) is what cut-outs come from
        for f in ordered {
            guard let sha = f["sha256"] as? String else { continue }
            let src = dir.appendingPathComponent((f["file"] as? String) ?? "\(sha).png")
            let n = frameNumber(f)
            let stored = "\(rec.id).frame-\(n).png"
            let dest = store.mediaFile(slug, stored)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            var p = Part(id: "frame-\(n)", name: (sha == posterSha ? "Frame \(n) (best)" : "Frame \(n)"), source: "frame", kind: "title-screen", picked: false, auto: false)
            p.file = stored
            p.size = [(f["width"] as? Int) ?? 0, (f["height"] as? Int) ?? 0]
            parts.append(p)
        }
        rec.parts = parts
        try await store.upsertMedia(slug, rec)
        await broadcastMedia(slug, rec)
        await analyse(slug, rec.id)
    }

    /// Finds cut-outs (the subject and each instance) in one of a video's frames and adds them as parts cut from it,
    /// next to the ones already found (from the best frame or others). Asking again for the same frame replaces only
    /// that frame's. Runs as a job; the media event follows.
    public func frameCutouts(_ slug: String, _ id: String, frame: String) async throws -> String {
        guard let rec = await store.mediaRecord(slug, id),
              let fp = rec.allParts.first(where: { $0.id == frame }), fp.source == "frame", let ff = fp.file else {
            throw IconLabError.notFound("frame \(frame)")
        }
        let label = fp.name
        return await jobs.enqueue(title: "Cut-outs · \(rec.name) · \(label)", program: slug, group: "analysis") { [self] progress in
            guard let img = Bitmap.load(store.mediaFile(slug, ff)) else { throw IconLabError.notFound(ff) }
            await progress(0.2, "Vision")
            let r = Analyser.analyse(img, name: rec.name, knownKind: rec.kind == "unknown" ? nil : rec.kind)
            let title = await store.program(slug)?.title ?? slug
            let found = PartsFinder.find(img, analysis: r, kind: rec.kind, programTitle: title)
            let n = frame.replacingOccurrences(of: "frame-", with: "")
            var added: [Part] = []
            for var p in found.parts where p.source == "subject" || p.source == "instance" {
                let old = p.id
                p.id = "f\(n)-\(old)"
                p.name = "\(p.name) (frame \(n))"
                p.frame = frame
                p.auto = false
                if let m = found.masks[old] { try m.writePNG(to: assets.partMaskFile(slug, id, p.id)) }
                added.append(p)
            }
            guard var cur = await store.mediaRecord(slug, id) else { return }
            let prefix = "f\(n)-"
            let keepPicks = Dictionary(cur.allParts.filter { $0.id.hasPrefix(prefix) }.map { ($0.id, $0.picked) }) { a, _ in a }
            for i in added.indices { added[i].picked = keepPicks[added[i].id] ?? false }
            cur.parts = cur.allParts.filter { !$0.id.hasPrefix(prefix) } + added
            try await store.upsertMedia(slug, cur)
            cur = await sizeParts(slug, cur)
            try await store.upsertMedia(slug, cur)
            await broadcastMedia(slug, cur)
            await progress(1, added.isEmpty ? "No cut-outs found" : "\(added.count) found")
        }
    }

    static func provenanceString(_ r: [String: Any]) -> String {
        if let s = r["provenance"] as? String { return s }
        if let ps = r["provenance"] as? [[String: Any]], let s = ps.first?["display"] as? String { return s }
        if let ps = r["provenances"] as? [[String: Any]], let first = ps.first {
            if let s = first["display"] as? String { return s }
        }
        if let chains = r["chains"] as? [[String: Any]], let first = chains.first, let s = first["display"] as? String { return s }
        if let ds = r["display"] as? [String], let s = ds.first { return s }
        return r["name"] as? String ?? "your files"
    }
}
