import Foundation
import Logging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Sources")

// Sites read as HTML, politely: each fetch checks robots.txt, goes through the host's gate (Macintosh Repository
// 10 s apart, as its robots.txt asks; the others 3 s), and is cached. All three disallow their search pages, so:
// - My Abandonware: searched in a local copy of the sitemap its robots.txt points to (refreshed weekly);
// - WinWorld: a product page looked up by the slug the query would have (one fetch, cached either way);
// - Macintosh Repository: no search at all; its pages are read only for programs Wikidata links to it.

nonisolated enum HTML {
    static func decode(_ s: String) -> String {
        var t = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> [[String]] {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    static func first(_ pattern: String, in text: String) -> String? { matches(pattern, in: text).first.flatMap { $0.count > 1 ? decode($0[1]) : nil } }
}

// MARK: My Abandonware

nonisolated public final class MyAbandonwareSource: ProgramSource, MediaSource, LocalCopySource {
    let ctx: SourceContext
    let index: LocalIndex
    static let sitemap = "https://www.myabandonware.com/sitemap.xml.gz"

    public init(_ ctx: SourceContext) {
        self.ctx = ctx
        index = LocalIndex(dir: ctx.sourcesDir.appendingPathComponent("myabandonware"))
    }

    public var info: SourceInfo {
        get async {
            let ready = await index.exists
            return SourceInfo(id: "myabandonware", name: "My Abandonware", state: ready ? .ready : .disabled,
                              note: ready ? "local copy of its sitemap" : (await index.building) ? "downloading its sitemap…" : "no local copy yet",
                              local: true, homepage: "https://www.myabandonware.com")
        }
    }

    public func refreshIfNeeded(force: Bool = false) async {
        guard await index.needsRefresh(force: force) else { return }
        let dir = index.dir, http = ctx.http, index = self.index
        await ctx.jobs.enqueue(title: "Update My Abandonware's game list", group: "sources") { progress in
            try await index.rebuild { out in
                await progress(0.05, "Downloading its sitemap")
                let sitemap = try URL.required(Self.sitemap)
                guard await http.robotsAllow(sitemap) else { throw FetchError.robots(sitemap.absoluteString) }
                let gz = dir.appendingPathComponent("sitemap.xml.gz")
                _ = try await http.download(sitemap, to: gz) { _, _ in }
                await progress(0.5, "Indexing games")
                let unzipped = try await Process.output(of: "/usr/bin/gunzip", ["-c", gz.path])
                if !unzipped.succeeded { logger.warning("gunzip of My Abandonware's sitemap exited \(unzipped.status): \(unzipped.errorOutput.suffix(400))") }
                try await Blocking.run { try Self.build(xml: unzipped.output, out: out) }
            }
        }
    }

    static func build(xml: String, out: URL) throws {
        let db = try SQLiteDB(path: out.path)
        try db.exec("""
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
            CREATE TABLE games(id TEXT PRIMARY KEY, slug TEXT, name TEXT, shot TEXT);
            CREATE VIRTUAL TABLE names USING fts5(name, game UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
            BEGIN;
            """)
        let g = try db.prepare("INSERT OR IGNORE INTO games VALUES (?, ?, ?, ?)")
        let n = try db.prepare("INSERT INTO names(name, game) VALUES (?, ?)")
        for entry in xml.components(separatedBy: "<url>").dropFirst() {
            guard let loc = HTML.first("<loc>https://www\\.myabandonware\\.com/game/([^<]+)</loc>", in: entry) else { continue }
            let (slug, id) = split(loc)
            guard !id.isEmpty else { continue }
            let caption = HTML.first("<image:caption>In game screenshot of (.*?)</image:caption>", in: entry)
            let name = caption ?? slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            let shot = HTML.first("<image:loc>(.*?)</image:loc>", in: entry)?.replacingOccurrences(of: "http://", with: "https://")
            g.run([id, slug, name, shot])
            n.run([name, id])
        }
        try db.exec("COMMIT;")
    }

    /// "logical-journey-of-the-zoombinis-3ei" → ("logical-journey-of-the-zoombinis", "3ei")
    static func split(_ path: String) -> (String, String) {
        guard let dash = path.lastIndex(of: "-") else { return (path, "") }
        return (String(path[..<dash]), String(path[path.index(after: dash)...]))
    }

    public func search(_ query: String) async throws -> [ProgramHit] {
        guard let db = await index.open(), let fts = SQLiteDB.ftsQuery(query) else { return [] }
        let rows = try db.query("""
            SELECT g.id, g.slug, g.name, g.shot FROM names JOIN games g ON g.id = names.game
            WHERE names MATCH ? ORDER BY bm25(names) LIMIT 40
            """, [fts])
        var hits: [ProgramHit] = rows.compactMap { r in
            guard let id = r[0] as? String, let slug = r[1] as? String, let name = r[2] as? String else { return nil }
            var h = ProgramHit(source: "myabandonware", sourceId: id, title: name)
            h.url = "https://www.myabandonware.com/game/\(slug)-\(id)"
            h.thumb = r[3] as? String
            h.kind = "game"
            return h
        }
        hits.sort { Titles.similarity(query, $0.title) > Titles.similarity(query, $1.title) }
        return Array(hits.prefix(15))
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var ids = program.idList("myabandonware")
        if ids.isEmpty {
            ids = try await search(program.title).filter { Titles.base($0.title) == Titles.base(program.title) }.prefix(1).map(\.sourceId)
        }
        var out: [RemoteMedia] = []
        for id in ids.prefix(2) {
            let r = try await ctx.http.fetch(URL.required("https://www.myabandonware.com/game/--\(id)"), cache: .api, checkRobots: true)
            let page = r.url.absoluteString
            let slugBase = Self.split(r.url.lastPathComponent).0
            var seen = Set<String>()
            for m in HTML.matches("href=\"(/media/screenshots/[^\"]+\\.(?:jpg|png|gif))\"", in: r.text) {
                let path = m[1]
                let dir = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
                guard dir.hasPrefix(slugBase), seen.insert(path).inserted else { continue }
                out.append(remote("myabandonware", "https://www.myabandonware.com" + path, label: "screenshot", title: (path as NSString).lastPathComponent,
                                  page: page))
                if seen.count >= 8 { break }
            }
        }
        return out
    }
}

// MARK: WinWorld

nonisolated public struct WinWorldSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo {
        get async { SourceInfo(id: "winworld", name: "WinWorld", state: .ready, note: "looked up by name (its search is closed to robots)", homepage: "https://winworldpc.com") }
    }

    static func slugs(_ q: String) -> [String] {
        let toks = Titles.tokens(q, keepStopwords: true)
        var out = [toks.joined(separator: "-")]
        if toks.count > 1, ["microsoft", "apple", "ms"].contains(toks[0]) { out.append(toks.dropFirst().joined(separator: "-")) }
        return out.filter { !$0.isEmpty }
    }

    func page(_ slug: String) async throws -> HTTPResult? {
        let r = try await ctx.http.fetch(URL.required("https://winworldpc.com/product/\(slug)"), cache: .search, checkRobots: true, cacheNotFound: true)
        return r.status == 404 || !r.text.contains("<dt>Vendor</dt>") ? nil : r
    }

    public func search(_ query: String) async throws -> [ProgramHit] {
        var hits: [ProgramHit] = []
        for slug in Self.slugs(query) {
            if let r = try await page(slug), let h = Self.parseProduct(r.text, slug: slug) { hits.append(h); break }
        }
        return hits
    }

    static func parseProduct(_ html: String, slug: String) -> ProgramHit? {
        guard var title = HTML.first("<title>WinWorld: (.*?)</title>", in: html) else { return nil }
        title = title.replacingOccurrences(of: "\\s+[0-9][0-9.x]*$", with: "", options: .regularExpression)
        var h = ProgramHit(source: "winworld", sourceId: slug, title: title)
        h.developer = HTML.first("<dt>Vendor</dt>\\s*<dd>(?:<a[^>]*>)?(.*?)(?:</a>)?</dd>", in: html)
        h.year = firstYear(HTML.first("<dt>Release date</dt>\\s*<dd>(.*?)</dd>", in: html))
        h.platforms = HTML.matches("badge-info\"[^>]*>([^<]+)</a>", in: html).map { HTML.decode($0[1]) }.map { $0 == "MacOS" ? "Mac OS" : $0 }
        let type = HTML.first("badge-primary\"[^>]*>([^<]+)</a>", in: html) ?? ""
        h.kind = type.lowercased().contains("game") ? "game" : "software"
        h.summary = type
        h.url = "https://winworldpc.com/product/\(slug)"
        if let shot = HTML.matches("(?:src|data-src)=\"(/res/img/screenshots/[^\"]+)\"", in: html).first?[1] {
            h.thumb = "https://winworldpc.com" + (shot.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? shot)
        }
        h.tidy()
        return h
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var slugs = program.idList("winworld")
        if slugs.isEmpty { slugs = Self.slugs(program.title) }
        for slug in slugs.prefix(2) {
            guard let r = try await page(slug) else { continue }
            let pageURL = "https://winworldpc.com/product/\(slug)"
            var seen = Set<String>()
            return HTML.matches("(?:src|data-src)=\"(/res/img/screenshots/[^\"]+)\"[^>]*alt=\"([^\"]*)\"", in: r.text).compactMap { m in
                guard seen.insert(m[1]).inserted else { return nil }
                let alt = HTML.decode(m[2])
                return remote("winworld", "https://winworldpc.com" + (m[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m[1]),
                              label: alt, kind: MediaLabels.kind(alt) == "other" ? "screenshot" : MediaLabels.kind(alt), title: alt, page: pageURL)
            }
        }
        return []
    }
}

// MARK: Macintosh Repository

nonisolated public struct MacintoshRepositorySource: MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo {
        get async {
            SourceInfo(id: "macintoshrepository", name: "Macintosh Repository", state: .ready,
                       note: "no search (closed to robots): read for programs Wikidata links to it, 10 s apart", homepage: "https://www.macintoshrepository.org")
        }
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var out: [RemoteMedia] = []
        for id in program.idList("macintoshrepository").prefix(2) {
            let r = try await ctx.http.fetch(URL.required("https://www.macintoshrepository.org/\(id)-_"), cache: .api, checkRobots: true)
            out += Self.parsePage(r.text, page: r.url.absoluteString)
        }
        return out
    }

    /// The slideshow's pictures (the site serves them resized to 640×480), labelled ones first, at most 8.
    static func parsePage(_ html: String, page: String) -> [RemoteMedia] {
        let items = HTML.matches("<img src=\"(https://www\\.macintoshrepository\\.org/_resize\\.php\\?[^\"]+)\" alt=\"([^\"]*)\"", in: html)
        let all = items.map { m -> RemoteMedia in
            let alt = HTML.decode(m[2])
            let url = HTML.decode(m[1])
            return remote("macintoshrepository", url, label: alt.isEmpty ? nil : alt, kind: alt.isEmpty ? "other" : MediaLabels.kind(alt),
                          width: 640, height: 480, title: alt.isEmpty ? "Picture" : alt, page: page)
        }
        return Array((all.filter { $0.sourceLabel != nil } + all.filter { $0.sourceLabel == nil }).prefix(8))
    }

    static func year(_ html: String) -> Int? { firstYear(HTML.first("Year: </span>([0-9]{4})", in: html)) }
}

// MARK: Link-only sources

/// Sites that forbid automated access (or charge for it): listed, and linked from results through the ids Wikidata
/// gives (or a search link for a person to open).
nonisolated public struct LinkOnlySource: Sendable {
    public let info: SourceInfo
    public static let all: [LinkOnlySource] = [
        .init(info: SourceInfo(id: "mobygames", name: "MobyGames", state: .linkOnly, note: "API needs a paid key; linked through Wikidata", homepage: "https://www.mobygames.com")),
        .init(info: SourceInfo(id: "macintoshgarden", name: "Macintosh Garden", state: .linkOnly, note: "robots.txt forbids robots; linked through Wikidata", homepage: "https://macintoshgarden.org")),
        .init(info: SourceInfo(id: "discmaster", name: "Discmaster", state: .linkOnly, note: "robots.txt forbids robots; a search link", homepage: "https://discmaster.textfiles.com")),
        .init(info: SourceInfo(id: "gamefaqs", name: "GameFAQs", state: .linkOnly, note: "its terms forbid scraping; linked through Wikidata", homepage: "https://gamefaqs.gamespot.com")),
    ]

    /// Links a person can open for a result: search pages for the link-only sites that have no id for it.
    static func searchLinks(title: String, platforms: [String], ids: [String: String]) -> [String: String] {
        let q = title.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? title
        var out = ["discmaster": "https://discmaster.textfiles.com/search?q=\(q)"]
        if ids["mobygames"] == nil && ids["mobygames-slug"] == nil { out["mobygames"] = "https://www.mobygames.com/search/?q=\(q)" }
        if ids["macintoshgarden"] == nil, platforms.contains(where: { $0.hasPrefix("Mac") }) || platforms.isEmpty {
            out["macintoshgarden"] = "https://macintoshgarden.org/search/node/\(q)"
        }
        return out
    }
}
