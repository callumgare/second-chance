import CryptoKit
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Store")

/// Where everything lives: `data/programs/<slug>/` per program, `data/cache/` for renders.
///
/// A program folder holds `program.json`, `media.json` and `media/<file>` (its images), `masks/<id>.png` (subject
/// masks), `docs/<id>.json` (every document, kept as sent), `state.json` (pins and the open document) and `saved/`.
public actor Store {
    public let root: URL
    public var cacheDir: URL { root.appendingPathComponent("cache") }
    private var mediaCache: [String: [MediaRecord]] = [:]

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("programs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
    }

    public nonisolated func dir(_ slug: String) -> URL { root.appendingPathComponent("programs").appendingPathComponent(slug) }
    public nonisolated func mediaFile(_ slug: String, _ file: String) -> URL { dir(slug).appendingPathComponent("media").appendingPathComponent(file) }
    public nonisolated func maskFile(_ slug: String, _ id: String) -> URL { dir(slug).appendingPathComponent("masks").appendingPathComponent("\(id).png") }

    // MARK: Programs

    public struct ProgramInfo: Codable, Sendable {
        public var slug: String
        public var title: String
        public var year: Int?
        public var ids: [String: String]?   // other catalogues' ids for it (stage 1)
        public var platforms: [String]?
        public var updated: String?
        public var developer: String?
        public var publisher: String?
        /// The host's bundle for it (`freeware/skifree`), when it was opened from the host's programs.
        public var bundleId: String?
    }

    public func programs() -> [ProgramInfo] {
        let base = root.appendingPathComponent("programs")
        let slugs = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return slugs.compactMap { program($0) }.sorted { ($0.updated ?? "") > ($1.updated ?? "") }
    }

    public func program(_ slug: String) -> ProgramInfo? {
        guard let d = try? Data(contentsOf: dir(slug).appendingPathComponent("program.json")) else { return nil }
        return try? JSONDecoder().decode(ProgramInfo.self, from: d)
    }

    public func saveProgram(_ p: ProgramInfo) throws {
        var p = p
        p.updated = ISO8601DateFormatter().string(from: Date())
        try FileManager.default.createDirectory(at: dir(p.slug), withIntermediateDirectories: true)
        try Store.json(p).write(to: dir(p.slug).appendingPathComponent("program.json"), options: .atomic)
    }

    public func touch(_ slug: String) {
        guard let p = program(slug) else { return }
        do { try saveProgram(p) } catch { logger.error("Couldn't save \(slug)'s program.json: \(error)") }
    }

    // MARK: Media

    public func media(_ slug: String) -> [MediaRecord] {
        if let m = mediaCache[slug] { return m }
        let url = dir(slug).appendingPathComponent("media.json")
        let m = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([MediaRecord].self, from: $0) } ?? []
        mediaCache[slug] = m
        return m
    }

    public func mediaRecord(_ slug: String, _ id: String) -> MediaRecord? { media(slug).first { $0.id == id } }

    public func saveMedia(_ slug: String, _ records: [MediaRecord]) throws {
        mediaCache[slug] = records
        try FileManager.default.createDirectory(at: dir(slug), withIntermediateDirectories: true)
        try Store.json(records).write(to: dir(slug).appendingPathComponent("media.json"), options: .atomic)
    }

    public func upsertMedia(_ slug: String, _ record: MediaRecord) throws {
        var all = media(slug)
        if let i = all.firstIndex(where: { $0.id == record.id }) { all[i] = record } else { all.append(record) }
        try saveMedia(slug, all)
    }

    /// Adds an image file to a program (copied in), returning its new record (not yet analysed).
    public func addMedia(_ slug: String, from file: URL, name: String? = nil, source: String, sourceUrl: String? = nil,
                         provenance: String? = nil, kind: String? = nil) throws -> MediaRecord {
        let data = try Data(contentsOf: file)
        let hash = Store.sha256(data).prefix(10)
        let name = name ?? file.lastPathComponent
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let id = Store.slugify((name as NSString).deletingPathExtension) + "-" + hash
        if let existing = mediaRecord(slug, String(id)) { return existing }
        let stored = "\(id).\(ext)"
        let dest = mediaFile(slug, stored)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        let bmp = Bitmap.load(dest)
        let rec = MediaRecord(id: String(id), name: name, file: stored, kind: kind ?? "other", source: source,
                              sourceUrl: sourceUrl, provenance: provenance, width: bmp?.width ?? 0, height: bmp?.height ?? 0)
        try upsertMedia(slug, rec)
        return rec
    }

    /// Replaces a media item's file with a larger copy (keeping its id).
    public func replaceMediaFile(_ slug: String, _ id: String, with file: URL) throws {
        guard var rec = mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
        let old = mediaFile(slug, rec.file)
        let stored = "\(id).\(ext)"
        let dest = mediaFile(slug, stored)
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: file, to: dest)
        rec.file = stored
        try upsertMedia(slug, rec)
    }

    // MARK: Documents

    public struct State: Codable, Sendable {
        public var pins: [String] = []
        public var current: String?
        public init() {}
    }

    public func state(_ slug: String) -> State {
        (try? Data(contentsOf: dir(slug).appendingPathComponent("state.json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    public func saveState(_ slug: String, _ s: State) throws {
        try FileManager.default.createDirectory(at: dir(slug), withIntermediateDirectories: true)
        try Store.json(s).write(to: dir(slug).appendingPathComponent("state.json"), options: .atomic)
    }

    /// Every document as stored (raw JSON objects, so unknown keys survive).
    public func docs(_ slug: String) -> [Data] {
        let d = dir(slug).appendingPathComponent("docs")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return files.compactMap { try? Data(contentsOf: d.appendingPathComponent($0)) }
    }

    public func doc(_ slug: String, _ id: String) -> Data? {
        try? Data(contentsOf: dir(slug).appendingPathComponent("docs").appendingPathComponent("\(Store.slugify(id)).json"))
    }

    public func saveDoc(_ slug: String, id: String, json: Data) throws {
        let d = dir(slug).appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try json.write(to: d.appendingPathComponent("\(Store.slugify(id)).json"), options: .atomic)
    }

    // MARK: Helpers

    public static func json<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(v)
    }

    public static func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    public static func slugify(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var out = ""
        for ch in s.lowercased() {
            if allowed.contains(ch) { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
    }
}
