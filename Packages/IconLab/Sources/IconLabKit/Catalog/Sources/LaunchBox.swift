import Foundation
import Logging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Sources")

/// LaunchBox's games database: `Metadata.zip` (≈110 MB, rebuilt daily) downloaded into `data/sources/launchbox/`,
/// its PC and Mac games indexed into SQLite with FTS5, refreshed weekly. Searches and media lookups are local; images
/// come from LaunchBox's CDN.
nonisolated public final class LaunchBoxSource: ProgramSource, MediaSource, LocalCopySource {
    let ctx: SourceContext
    let index: LocalIndex
    static let platforms: Set<String> = ["Windows", "MS-DOS", "Windows 3.X", "Apple Mac OS"]
    static let zipURL = URL(string: "https://gamesdb.launchbox-app.com/Metadata.zip")!

    public init(_ ctx: SourceContext) {
        self.ctx = ctx
        index = LocalIndex(dir: ctx.sourcesDir.appendingPathComponent("launchbox"))
    }

    public var info: SourceInfo {
        get async {
            let ready = await index.exists, building = await index.building
            let note = ready ? "local copy" : building ? "downloading its database…" : (await index.lastError).map { "couldn't build its database: \($0)" } ?? "no local copy yet"
            return SourceInfo(id: "launchbox", name: "LaunchBox", state: ready ? .ready : .disabled, note: note, local: true,
                              homepage: "https://gamesdb.launchbox-app.com")
        }
    }

    // MARK: Local copy

    public func refreshIfNeeded(force: Bool = false) async {
        guard await index.needsRefresh(force: force) else { return }
        let dir = index.dir, http = ctx.http, index = self.index
        await ctx.jobs.enqueue(title: "Update LaunchBox's games database", group: "sources") { progress in
            try await index.rebuild { out in
                let zip = dir.appendingPathComponent("Metadata.zip")
                await progress(0.01, "Downloading Metadata.zip")
                let changed = try await http.download(Self.zipURL, to: zip) { done, total in
                    guard let total, total > 0 else { return }
                    Task { await progress(0.5 * Double(done) / Double(total), "Downloading Metadata.zip (\(done / 1_000_000) of \(total / 1_000_000) MB)") }
                }
                if !changed, await index.exists, !force {
                    // unchanged: keep the index we have (rebuild needs a file, so copy it)
                    try FileManager.default.copyItem(at: await index.dbFile, to: out)
                    return
                }
                await progress(0.5, "Unpacking Metadata.xml")
                let xml = dir.appendingPathComponent("Metadata.xml")
                try? FileManager.default.removeItem(at: xml)
                try await Self.run("/usr/bin/unzip", ["-o", "-q", zip.path, "Metadata.xml", "-d", dir.path])
                defer { try? FileManager.default.removeItem(at: xml) }
                await progress(0.6, "Indexing games")
                let size = ((try? FileManager.default.attributesOfItem(atPath: xml.path)[.size]) as? NSNumber)?.int64Value ?? 1
                try await Blocking.run {
                    try LaunchBoxIndexer(xml: xml, out: out, size: size) { p in Task { await progress(0.6 + 0.39 * p, "Indexing games") } }.run()
                }
            }
        }
    }

    static func run(_ tool: String, _ args: [String]) async throws {
        let r = try await Process.output(of: tool, args)
        guard r.succeeded else {
            logger.error("\(tool) exited \(r.status): \(r.errorOutput.suffix(400))")
            throw IconLabError.tool("\(tool) exited \(r.status)")
        }
    }

    // MARK: Search

    public func search(_ query: String) async throws -> [ProgramHit] {
        guard let db = await index.open(), let fts = SQLiteDB.ftsQuery(query) else { return [] }
        return try Self.search(db, query: query, fts: fts)
    }

    static func search(_ db: SQLiteDB, query: String, fts: String, limit: Int = 25) throws -> [ProgramHit] {
        let rows = try db.query("SELECT game, name FROM names WHERE names MATCH ? ORDER BY bm25(names) LIMIT 150", [fts])
        var matchedNames: [Int: [String]] = [:], order: [Int] = []
        for r in rows {
            guard let g = r[0] as? Int, let n = r[1] as? String else { continue }
            if matchedNames[g] == nil { order.append(g) }
            matchedNames[g, default: []].append(n)
        }
        guard !order.isEmpty else { return [] }
        let list = order.prefix(80).map(String.init).joined(separator: ",")
        var hits: [ProgramHit] = []
        for r in try db.query("SELECT id, name, year, platform, developer, publisher, wikipedia, steam, genres FROM games WHERE id IN (\(list))") {
            guard let id = r[0] as? Int, let name = r[1] as? String else { continue }
            var h = ProgramHit(source: "launchbox", sourceId: String(id), title: name)
            h.year = r[2] as? Int
            h.platforms = [(r[3] as? String) ?? ""]
            h.developer = r[4] as? String
            h.publisher = r[5] as? String
            if let w = r[6] as? String, let t = w.components(separatedBy: "/wiki/").last { h.ids["wikipedia"] = t.removingPercentEncoding ?? t }
            if let s = r[7] as? String { h.ids["steam"] = s }
            let genres = (r[8] as? String) ?? ""
            h.kind = genres.contains("Compilation") ? "compilation" : "game"
            h.alternateTitles = (matchedNames[id] ?? []).filter { $0 != name }
            h.url = Self.searchURL(name)
            hits.append(h)
        }
        hits.sort { Titles.similarity(query, $0.title) > Titles.similarity(query, $1.title) }
        hits = Array(hits.prefix(limit))
        for i in hits.indices {
            if let f = try db.query("""
                SELECT file FROM images WHERE game = ? AND type = 'Box - Front'
                ORDER BY (region = 'North America') DESC, (region IS NULL) DESC, (region = 'United States') DESC LIMIT 1
                """, [Int(hits[i].sourceId)]).first?.first as? String {
                hits[i].thumb = "https://images.launchbox-app.com/\(f)"
            }
            hits[i].tidy()
        }
        return hits
    }

    // MARK: Pages

    static func searchURL(_ name: String) -> String {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? name
        return "https://gamesdb.launchbox-app.com/games/results/\(q)"
    }

    /// A game's page on LaunchBox's website. The website numbers its pages differently from the data's DatabaseID,
    /// and the data has no link between them, so the page is found by searching the site for the game's name and
    /// taking the one result whose slug is the name's; with none or several, the search itself.
    static func pageURL(_ http: HTTP, name: String) async -> String {
        let search = searchURL(name)
        guard let url = URL(string: search), let r = try? await http.fetch(url, cache: .search),
              let html = String(data: r.data, encoding: .utf8) else { return search }
        let want = Titles.slug(name)
        var found = Set<String>()
        for m in html.matches(of: /href="\/games\/details\/(\d+)-([a-z0-9-]+)"/) where String(m.output.2) == want {
            found.insert("https://gamesdb.launchbox-app.com/games/details/\(m.output.1)-\(m.output.2)")
        }
        guard found.count == 1, let page = found.first else { return search }
        return page
    }

    // MARK: Media

    static let typeCaps: [String: Int] = ["Screenshot - Gameplay": 6, "Fanart - Background": 3, "Advertisement Flyer - Front": 2,
                                          "Advertisement Flyer - Back": 1, "Banner": 2, "Steam Banner": 1, "Square": 2]
    static let skipTypes: Set<String> = ["Arcade - Cabinet", "Arcade - Circuit Board", "Arcade - Control Panel", "Arcade - Controls Information",
                                         "Cart - Back", "Cart - 3D", "Clear Logo - Reconstructed"]

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        guard let db = await index.open() else { return [] }
        var ids = program.idList("launchbox").compactMap(Int.init)
        if ids.isEmpty, let fts = SQLiteDB.ftsQuery(program.title) {
            // not linked: the same title (and year, if we know it) in the local copy
            ids = try Self.search(db, query: program.title, fts: fts).filter {
                Titles.normalise($0.title) == Titles.normalise(program.title) && Titles.yearsClose($0.year, program.year)
            }.compactMap { Int($0.sourceId) }
        }
        guard !ids.isEmpty else { return [] }
        let rows = try db.query("SELECT game, file, type, region FROM images WHERE game IN (\(ids.map(String.init).joined(separator: ","))) ORDER BY game, type, region")
        var counts: [String: Int] = [:]
        var out: [RemoteMedia] = []
        // each game's page on the website, found by its name (one search per game, cached for a week)
        var pages: [Int: String] = [:]
        for id in ids {
            guard let name = try db.query("SELECT name FROM games WHERE id = ?", [id]).first?.first as? String else { continue }
            pages[id] = await Self.pageURL(ctx.http, name: name)
        }
        for r in rows {
            guard let game = r[0] as? Int, let file = r[1] as? String, let type = r[2] as? String, !Self.skipTypes.contains(type) else { continue }
            let capKey = "\(game)|\(type)"
            counts[capKey, default: 0] += 1
            if let cap = Self.typeCaps[type], counts[capKey, default: 0] > cap { continue }
            out.append(remote("launchbox", "https://images.launchbox-app.com/\(file)", label: type, region: r[3] as? String,
                              title: type, page: pages[game]))
        }
        return out
    }
}

/// Streams Metadata.xml into a new SQLite index: PC and Mac games, their alternate names (FTS5) and their images.
nonisolated final class LaunchBoxIndexer: NSObject, XMLParserDelegate {
    let xml: URL, out: URL, size: Int64
    let progress: (Double) -> Void
    var db: SQLiteDB!
    var insGame: SQLiteDB.Statement!, insName: SQLiteDB.Statement!, insImage: SQLiteDB.Statement!
    var included = Set<Int>()
    var fields: [String: String] = [:]
    var text = ""
    var depth = 0
    var record = ""          // Game | GameAlternateName | GameImage
    let wanted: Set<String> = ["Name", "ReleaseDate", "ReleaseYear", "DatabaseID", "Platform", "Developer", "Publisher", "WikipediaURL",
                               "SteamAppId", "Genres", "AlternateName", "FileName", "Type", "Region"]
    var stream: InputStream?
    var count = 0

    init(xml: URL, out: URL, size: Int64, progress: @escaping (Double) -> Void) {
        self.xml = xml; self.out = out; self.size = size; self.progress = progress
    }

    func run() throws {
        db = try SQLiteDB(path: out.path)
        try db.exec("""
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
            CREATE TABLE games(id INTEGER PRIMARY KEY, name TEXT, year INTEGER, platform TEXT, developer TEXT, publisher TEXT,
                               wikipedia TEXT, steam TEXT, genres TEXT);
            CREATE VIRTUAL TABLE names USING fts5(name, game UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE images(game INTEGER, file TEXT, type TEXT, region TEXT);
            BEGIN;
            """)
        insGame = try db.prepare("INSERT OR REPLACE INTO games VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        insName = try db.prepare("INSERT INTO names(name, game) VALUES (?, ?)")
        insImage = try db.prepare("INSERT INTO images VALUES (?, ?, ?, ?)")
        guard let s = InputStream(url: xml) else { throw IconLabError.tool("can't read Metadata.xml") }
        stream = s
        let parser = XMLParser(stream: s)
        parser.delegate = self
        guard parser.parse() else { throw IconLabError.tool("Metadata.xml: \(parser.parserError.map { "\($0)" } ?? "parse failed")") }
        try db.exec("COMMIT; CREATE INDEX images_game ON images(game);")
        insGame = nil; insName = nil; insImage = nil
        db = nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 2 { record = name; fields = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth == 3 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 3, wanted.contains(name) { fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if depth == 2 { finish() }
        depth -= 1
    }

    func finish() {
        count += 1
        if count % 20000 == 0, let s = stream, let off = s.property(forKey: .fileCurrentOffsetKey) as? NSNumber {
            progress(min(1, Double(off.int64Value) / Double(max(1, size))))
        }
        switch record {
        case "Game":
            guard let p = fields["Platform"], LaunchBoxSource.platforms.contains(p), let id = fields["DatabaseID"].flatMap(Int.init),
                  let name = fields["Name"] else { return }
            included.insert(id)
            let year = fields["ReleaseYear"].flatMap(Int.init) ?? firstYear(fields["ReleaseDate"])
            let platform = ["MS-DOS": "DOS", "Windows 3.X": "Windows 3.x", "Apple Mac OS": "Mac OS"][p] ?? p
            insGame.run([id, name, year, platform, fields["Developer"], fields["Publisher"], fields["WikipediaURL"], fields["SteamAppId"], fields["Genres"]])
            insName.run([name, id])
        case "GameAlternateName":
            guard let id = fields["DatabaseID"].flatMap(Int.init), included.contains(id), let n = fields["AlternateName"] else { return }
            insName.run([n, id])
        case "GameImage":
            guard let id = fields["DatabaseID"].flatMap(Int.init), included.contains(id), let f = fields["FileName"] else { return }
            insImage.run([id, f, fields["Type"], fields["Region"]])
        default: break
        }
    }
}
