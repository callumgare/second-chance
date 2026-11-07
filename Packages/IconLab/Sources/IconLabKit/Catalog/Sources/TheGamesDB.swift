import Foundation
import ProcessKit

/// TheGamesDB's free JSON dump (`database-latest.json`, no key needed; titles, dates, platforms, alternates — no
/// images), its PC and Mac games indexed locally, refreshed weekly. Its images need an API key (by forum request),
/// so for media we only try its CDN's predictable box and logo paths.
nonisolated public final class TheGamesDBSource: ProgramSource, MediaSource, LocalCopySource {
    let ctx: SourceContext
    let index: LocalIndex
    static let dumpURL = URL(string: "https://cdn.thegamesdb.net/json/database-latest.json")!
    static let platforms: [Int: String] = [1: "PC", 37: "Mac OS"]

    public init(_ ctx: SourceContext) {
        self.ctx = ctx
        index = LocalIndex(dir: ctx.sourcesDir.appendingPathComponent("thegamesdb"))
    }

    public var info: SourceInfo {
        get async {
            let ready = await index.exists, building = await index.building
            let note = ready ? "local copy" : building ? "downloading its database…" : (await index.lastError).map { "couldn't build its database: \($0)" } ?? "no local copy yet"
            return SourceInfo(id: "thegamesdb", name: "TheGamesDB", state: ready ? .ready : .disabled, note: note, local: true,
                              homepage: "https://thegamesdb.net")
        }
    }

    public func refreshIfNeeded(force: Bool = false) async {
        guard await index.needsRefresh(force: force) else { return }
        let dir = index.dir, http = ctx.http, index = self.index
        await ctx.jobs.enqueue(title: "Update TheGamesDB's games list", group: "sources") { progress in
            try await index.rebuild { out in
                let file = dir.appendingPathComponent("database-latest.json")
                await progress(0.01, "Downloading database-latest.json")
                let changed = try await http.download(Self.dumpURL, to: file) { done, total in
                    Task { await progress(0.6 * min(1, Double(done) / Double(total ?? 150_000_000)), "Downloading (\(done / 1_000_000) MB)") }
                }
                if !changed, await index.exists, !force {
                    try FileManager.default.copyItem(at: await index.dbFile, to: out)
                    return
                }
                await progress(0.6, "Indexing games")
                try await Blocking.run { try Self.build(json: file, out: out) }
            }
        }
    }

    struct Dump: Decodable {
        struct Data: Decodable { var games: [Game] }
        struct Game: Decodable {
            var id: Int
            var game_title: String?
            var release_date: String?
            var platform: Int?
            var alternates: [String]?
        }
        var data: Data
    }

    static func build(json: URL, out: URL) throws {
        let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: json, options: .mappedIfSafe))
        let db = try SQLiteDB(path: out.path)
        try db.exec("""
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
            CREATE TABLE games(id INTEGER PRIMARY KEY, name TEXT, year INTEGER, platform TEXT);
            CREATE VIRTUAL TABLE names USING fts5(name, game UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
            BEGIN;
            """)
        let g = try db.prepare("INSERT OR REPLACE INTO games VALUES (?, ?, ?, ?)")
        let n = try db.prepare("INSERT INTO names(name, game) VALUES (?, ?)")
        for game in dump.data.games {
            guard let p = game.platform, let platform = platforms[p], let title = game.game_title else { continue }
            var year = firstYear(game.release_date)
            if year == 1970 { year = nil }   // its "unknown"
            g.run([game.id, title, year, platform])
            n.run([title, game.id])
            for a in game.alternates ?? [] where a != title { n.run([a, game.id]) }
        }
        try db.exec("COMMIT;")
    }

    public func search(_ query: String) async throws -> [ProgramHit] {
        guard let db = await index.open(), let fts = SQLiteDB.ftsQuery(query) else { return [] }
        let rows = try db.query("SELECT game, name FROM names WHERE names MATCH ? ORDER BY bm25(names) LIMIT 100", [fts])
        var alts: [Int: [String]] = [:], order: [Int] = []
        for r in rows {
            guard let id = r[0] as? Int, let name = r[1] as? String else { continue }
            if alts[id] == nil { order.append(id) }
            alts[id, default: []].append(name)
        }
        guard !order.isEmpty else { return [] }
        var hits: [ProgramHit] = []
        for r in try db.query("SELECT id, name, year, platform FROM games WHERE id IN (\(order.prefix(60).map(String.init).joined(separator: ",")))") {
            guard let id = r[0] as? Int, let name = r[1] as? String else { continue }
            var h = ProgramHit(source: "thegamesdb", sourceId: String(id), title: name)
            h.year = r[2] as? Int
            h.platforms = [(r[3] as? String) ?? ""]
            h.alternateTitles = (alts[id] ?? []).filter { $0 != name }
            h.kind = "game"
            h.url = IDSpace.link("thegamesdb", String(id))
            h.tidy()
            hits.append(h)
        }
        hits.sort { Titles.similarity(query, $0.title) > Titles.similarity(query, $1.title) }
        return Array(hits.prefix(20))
    }

    /// Its CDN's usual paths for a game's box front, back and clear logo (they may not exist; a miss is skipped).
    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        program.idList("thegamesdb").prefix(3).flatMap { id -> [RemoteMedia] in
            let page = IDSpace.link("thegamesdb", id)
            return [
                remote("thegamesdb", "https://cdn.thegamesdb.net/images/original/boxart/front/\(id)-1.jpg",
                       thumb: "https://cdn.thegamesdb.net/images/thumb/boxart/front/\(id)-1.jpg", label: "boxart front", page: page),
                remote("thegamesdb", "https://cdn.thegamesdb.net/images/original/boxart/back/\(id)-1.jpg",
                       thumb: "https://cdn.thegamesdb.net/images/thumb/boxart/back/\(id)-1.jpg", label: "boxart back", page: page),
                remote("thegamesdb", "https://cdn.thegamesdb.net/images/original/clearlogo/\(id).png", label: "clearlogo", page: page),
            ]
        }
    }
}
