import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Sources")

// The sources that need keys: IGDB (a Twitch app), SteamGridDB, ScreenScraper (account + developer credentials) and
// Brave image search (paid per request: only on demand). Until the keys are in .env they say `needsKey` and which.

// MARK: IGDB

nonisolated public final class IGDBSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    let token: IGDBToken
    static let keys = ["IGDB_CLIENT_ID", "IGDB_CLIENT_SECRET"]

    public init(_ ctx: SourceContext) {
        self.ctx = ctx
        token = IGDBToken(file: ctx.sourcesDir.appendingPathComponent("igdb/token.json"))
    }

    public var info: SourceInfo {
        get async {
            let missing = ctx.missing(Self.keys)
            return SourceInfo(id: "igdb", name: "IGDB", state: missing.isEmpty ? .ready : .needsKey,
                              note: missing.isEmpty ? nil : ctx.needsKeyNote(missing), homepage: "https://www.igdb.com")
        }
    }

    func post(_ endpoint: String, _ body: String, cache: HTTPCache) async throws -> [JSONObject] {
        guard let id = ctx.env["IGDB_CLIENT_ID"], let secret = ctx.env["IGDB_CLIENT_SECRET"] else { throw FetchError.quota("IGDB needs keys") }
        for attempt in 0..<2 {
            let t = try await token.get(http: ctx.http, id: id, secret: secret, renew: attempt > 0)
            do {
                let r = try await ctx.http.fetch(URL.required("https://api.igdb.com/v4/\(endpoint)"), method: "POST",
                                                 headers: ["Client-ID": id, "Authorization": "Bearer \(t)", "Accept": "application/json"],
                                                 body: Data(body.utf8), cache: cache)
                return (try r.json() as? [JSONObject]) ?? []
            } catch FetchError.status(401, _) where attempt == 0 { continue }
        }
        return []
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\"" }

    public func search(_ query: String) async throws -> [ProgramHit] {
        let body = """
        search \(Self.quote(query)); fields name,slug,url,summary,first_release_date,platforms.name,cover.image_id,alternative_names.name,\
        involved_companies.company.name,involved_companies.developer,involved_companies.publisher,external_games.uid,\
        external_games.external_game_source,external_games.category,websites.url,game_type.type,version_parent,parent_game; limit 25;
        """
        return Self.parseGames(try await post("games", body, cache: .search))
    }

    static func parseGames(_ games: [JSONObject]) -> [ProgramHit] {
        games.compactMap { g in
            guard let id = g.str("id"), let name = g.str("name") else { return nil }
            var h = ProgramHit(source: "igdb", sourceId: id, title: name)
            if let t = g["first_release_date"] as? NSNumber { h.year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: t.doubleValue)) }
            h.platforms = g.arr("platforms").compactMap { $0.str("name") }
            h.alternateTitles = g.arr("alternative_names").compactMap { $0.str("name") }
            for c in g.arr("involved_companies") {
                let n = c.obj("company")?.str("name")
                if (c["developer"] as? Bool) == true, h.developer == nil { h.developer = n }
                if (c["publisher"] as? Bool) == true, h.publisher == nil { h.publisher = n }
            }
            if let slug = g.str("slug") { h.ids["igdb-slug"] = slug }
            for e in g.arr("external_games") {
                guard let uid = e.str("uid") else { continue }
                let src = e.int("external_game_source") ?? e.int("category")
                if src == 1 { h.ids["steam"] = [h.ids["steam"], uid].compactMap { $0 }.joined(separator: ",") }
                if src == 5 { h.ids["gog"] = [h.ids["gog"], uid].compactMap { $0 }.joined(separator: ",") }
            }
            for w in g.arr("websites") {
                if let u = w.str("url"), u.contains("en.wikipedia.org/wiki/"), let t = u.components(separatedBy: "/wiki/").last {
                    h.ids["wikipedia"] = t.removingPercentEncoding ?? t
                }
            }
            switch g.obj("game_type")?.str("type")?.lowercased() ?? "" {
            case "remake", "remaster": h.kind = "remake"
            case "bundle": h.kind = "compilation"
            case "dlc", "dlc / addon", "expansion", "standalone expansion": h.kind = "expansion"
            default: h.kind = "game"
            }
            if let c = g.obj("cover")?.str("image_id") { h.thumb = "https://images.igdb.com/igdb/image/upload/t_cover_small/\(c).jpg" }
            h.url = g.str("url")
            h.summary = g.str("summary").map { String($0.prefix(300)) }
            h.tidy()
            return h
        }
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        guard ctx.missing(Self.keys).isEmpty else { return [] }
        let fields = "fields slug,url,cover.image_id,cover.width,cover.height,artworks.image_id,artworks.width,artworks.height,"
            + "screenshots.image_id,screenshots.width,screenshots.height;"
        var whereClause: String
        if !program.idList("igdb").isEmpty {
            whereClause = "where id = (\(program.idList("igdb").prefix(5).joined(separator: ",")));"
        } else if !program.idList("igdb-slug").isEmpty {
            whereClause = "where slug = (\(program.idList("igdb-slug").prefix(5).map(Self.quote).joined(separator: ",")));"
        } else {
            // not linked: search, and take an exact title match
            let hits = try await search(program.title)
            guard let h = hits.first(where: { Titles.normalise($0.title) == Titles.normalise(program.title) && Titles.yearsClose($0.year, program.year) })
            else { return [] }
            whereClause = "where id = \(h.sourceId);"
        }
        let games = try await post("games", "\(fields) \(whereClause) limit 5;", cache: .api)
        var out: [RemoteMedia] = []
        for g in games {
            let page = g.str("url")
            func add(_ items: [JSONObject], label: String, thumbSize: String, cap: Int) {
                for i in items.prefix(cap) {
                    guard let id = i.str("image_id") else { continue }
                    out.append(remote("igdb", "https://images.igdb.com/igdb/image/upload/t_original/\(id).jpg",
                                      thumb: "https://images.igdb.com/igdb/image/upload/t_\(thumbSize)/\(id).jpg", label: label,
                                      width: i.int("width"), height: i.int("height"), title: label, page: page))
                }
            }
            if let c = g.obj("cover") { add([c], label: "cover", thumbSize: "cover_big", cap: 1) }
            add(g.arr("artworks"), label: "artwork", thumbSize: "screenshot_med", cap: 8)
            add(g.arr("screenshots"), label: "screenshot", thumbSize: "screenshot_med", cap: 6)
        }
        return out
    }
}

/// The Twitch client-credentials token, cached in data/ until it expires.
actor IGDBToken {
    let file: URL
    private var token: String?
    private var expires = Date.distantPast
    init(file: URL) { self.file = file }

    struct Saved: Codable { var token: String; var expires: Date }

    func get(http: HTTP, id: String, secret: String, renew: Bool) async throws -> String {
        if !renew {
            if let token, expires > Date() { return token }
            if let d = try? Data(contentsOf: file), let s = try? JSONDecoder.iso.decode(Saved.self, from: d), s.expires > Date() {
                token = s.token; expires = s.expires
                return s.token
            }
        }
        let url = URL.make("https://id.twitch.tv/oauth2/token", [("client_id", id), ("client_secret", secret), ("grant_type", "client_credentials")])
        let j = try await http.fetch(url, method: "POST", cache: .none).json() as? JSONObject
        guard let t = j?.str("access_token") else { throw FetchError.badBody("twitch token", "no access_token") }
        let life = Double(j?.int("expires_in") ?? 3600)
        token = t
        expires = Date().addingTimeInterval(life - 3600)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(Saved(token: t, expires: expires)).write(to: file, options: .atomic)
        } catch {
            logger.warning("Couldn't keep IGDB's token: \(error)")
        }
        return t
    }
}

// MARK: SteamGridDB

nonisolated public struct SteamGridDBSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    static let keys = ["STEAMGRIDDB_API_KEY"]
    static let api = "https://www.steamgriddb.com/api/v2"

    public var info: SourceInfo {
        get async {
            let missing = ctx.missing(Self.keys)
            return SourceInfo(id: "steamgriddb", name: "SteamGridDB", state: missing.isEmpty ? .ready : .needsKey,
                              note: missing.isEmpty ? nil : ctx.needsKeyNote(missing), homepage: "https://www.steamgriddb.com")
        }
    }

    func get(_ path: String, cache: HTTPCache) async throws -> Any? {
        guard let key = ctx.env["STEAMGRIDDB_API_KEY"] else { return nil }
        let r = try await ctx.http.fetch(URL.required(Self.api + path), headers: ["Authorization": "Bearer \(key)"], cache: cache, cacheNotFound: true)
        return r.status == 404 ? nil : try r.json()
    }

    public func search(_ query: String) async throws -> [ProgramHit] {
        let term = query.addingPercentEncoding(withAllowedCharacters: .pathSegment) ?? query
        guard let j = try await get("/search/autocomplete/\(term)", cache: .search) as? JSONObject else { return [] }
        return Self.parseSearch(j)
    }

    static func parseSearch(_ j: JSONObject) -> [ProgramHit] {
        j.arr("data").compactMap { g in
            guard let id = g.str("id"), let name = g.str("name") else { return nil }
            var h = ProgramHit(source: "steamgriddb", sourceId: id, title: name)
            if let t = g["release_date"] as? NSNumber, t.doubleValue > 0 {
                h.year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: t.doubleValue))
            }
            h.kind = "game"
            h.url = IDSpace.link("steamgriddb", id)
            return h
        }
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        guard ctx.missing(Self.keys).isEmpty else { return [] }
        var ids = program.idList("steamgriddb")
        if ids.isEmpty, let steam = program.idList("steam").first, let j = try await get("/games/steam/\(steam)", cache: .api) as? JSONObject,
           let id = j.obj("data")?.str("id") { ids = [id] }
        if ids.isEmpty {
            ids = try await search(program.title).filter { Titles.normalise($0.title) == Titles.normalise(program.title) }.prefix(1).map(\.sourceId)
        }
        var out: [RemoteMedia] = []
        for id in ids.prefix(2) {
            for (kind, label, cap) in [("grids", "grid", 8), ("logos", "logo", 8), ("icons", "icon", 8), ("heroes", "hero", 4)] {
                guard let j = try await get("/\(kind)/game/\(id)?nsfw=false&humor=false", cache: .api) as? JSONObject else { continue }
                for i in j.arr("data").prefix(cap) {
                    guard let url = i.str("url") else { continue }
                    let w = i.int("width"), h = i.int("height")
                    var k = MediaLabels.kind(label)
                    if kind == "grids", let w, let h, w > h { k = "banner" }
                    let style = i.str("style").map { " · \($0)" } ?? ""
                    out.append(remote("steamgriddb", url, thumb: i.str("thumb"), label: "\(label)\(style)", kind: k, width: w, height: h,
                                      title: "\(label) \(w ?? 0)×\(h ?? 0)\(style)", page: "https://www.steamgriddb.com/\(label)/\(i.str("id") ?? "")"))
                }
            }
        }
        return out
    }
}

// MARK: ScreenScraper

nonisolated public final class ScreenScraperSource: ProgramSource, MediaSource, AuthorisingSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    static let keys = ["SCREEN_SCRAPER_USERNAME", "SCREEN_SCRAPER_PASSWORD", "SCREEN_SCRAPER_DEV_ID", "SCREEN_SCRAPER_DEV_PASSWORD"]
    static let api = "https://api.screenscraper.fr/api2"
    static let systems: Set<String> = ["DOS", "Windows 3.x", "Windows", "PC", "Mac OS"]
    nonisolated(unsafe) static var quotaUntil = Date.distantPast

    public var info: SourceInfo {
        get async {
            let missing = ctx.missing(Self.keys)
            if !missing.isEmpty { return SourceInfo(id: "screenscraper", name: "ScreenScraper", state: .needsKey, note: ctx.needsKeyNote(missing), homepage: "https://www.screenscraper.fr") }
            if Self.quotaUntil > Date() { return SourceInfo(id: "screenscraper", name: "ScreenScraper", state: .disabled, note: "today's quota is used up", homepage: "https://www.screenscraper.fr") }
            return SourceInfo(id: "screenscraper", name: "ScreenScraper", state: .ready, homepage: "https://www.screenscraper.fr")
        }
    }

    var credentials: [(String, String)] {
        [("devid", ctx.env["SCREEN_SCRAPER_DEV_ID"] ?? ""), ("devpassword", ctx.env["SCREEN_SCRAPER_DEV_PASSWORD"] ?? ""),
         ("softname", ctx.env["SCREEN_SCRAPER_SOFTNAME"] ?? "SecondChanceIconLab"), ("ssid", ctx.env["SCREEN_SCRAPER_USERNAME"] ?? ""),
         ("sspassword", ctx.env["SCREEN_SCRAPER_PASSWORD"] ?? "")]
    }

    func call(_ endpoint: String, _ params: [(String, String)], cache: HTTPCache) async throws -> JSONObject? {
        guard ctx.missing(Self.keys).isEmpty, Self.quotaUntil < Date() else { return nil }
        let r = try await ctx.http.fetch(.make("\(Self.api)/\(endpoint)", credentials + [("output", "json")] + params), cache: cache, cacheNotFound: true)
        if [430, 431].contains(r.status) { Self.quotaUntil = Date().addingTimeInterval(6 * 3600); throw FetchError.quota("ScreenScraper quota used up") }
        if r.status == 404 { return nil }
        return try r.json() as? JSONObject
    }

    public func search(_ query: String) async throws -> [ProgramHit] {
        guard let j = try await call("jeuRecherche.php", [("recherche", query)], cache: .search) else { return [] }
        return Self.parseGames(j.obj("response")?.arr("jeux") ?? [])
    }

    static func name(_ list: [JSONObject]) -> String? {
        for r in ["wor", "us", "ss", "eu", "uk"] { if let n = list.first(where: { $0.str("region") == r })?.str("text") { return n } }
        return list.first?.str("text")
    }

    static func parseGames(_ games: [JSONObject]) -> [ProgramHit] {
        games.compactMap { g in
            guard let id = g.str("id"), let title = name(g.arr("noms")) else { return nil }
            let system = g.obj("systeme")?.str("text").flatMap(Platforms.normalise)
            guard let system, systems.contains(system) else { return nil }
            var h = ProgramHit(source: "screenscraper", sourceId: id, title: title)
            h.platforms = [system]
            h.year = g.arr("dates").compactMap { firstYear($0.str("text")) }.min()
            h.developer = g.obj("developpeur")?.str("text")
            h.publisher = g.obj("editeur")?.str("text")
            h.alternateTitles = g.arr("noms").compactMap { $0.str("text") }
            h.kind = "game"
            h.url = IDSpace.link("screenscraper", id)
            if let m = g.arr("medias").first(where: { $0.str("type") == "box-2D" })?.str("url") { h.thumb = redact(m) + "&maxwidth=240&maxheight=240" }
            h.tidy()
            return h
        }
    }

    /// Media URLs come with the credentials in them: we store them without and add them back when downloading.
    static func redact(_ u: String) -> String {
        guard var c = URLComponents(string: u) else { return u }
        c.queryItems = c.queryItems?.filter { !["devid", "devpassword", "ssid", "sspassword", "softname"].contains($0.name) }
        return c.string ?? u
    }

    public func authorise(_ url: URL) async -> URL {
        guard url.host?.hasSuffix("screenscraper.fr") == true, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = credentials.map { URLQueryItem(name: $0.0, value: $0.1) } + (c.queryItems ?? [])
        return c.url ?? url
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var ids = program.idList("screenscraper")
        if ids.isEmpty {
            ids = try await search(program.title).filter { Titles.normalise($0.title) == Titles.normalise(program.title) }.prefix(2).map(\.sourceId)
        }
        var out: [RemoteMedia] = []
        for id in ids.prefix(3) {
            guard let j = try await call("jeuInfos.php", [("gameid", id)], cache: .api), let g = j.obj("response")?.obj("jeu") else { continue }
            for m in g.arr("medias") {
                guard let type = m.str("type"), let url = m.str("url"), m.str("format") != "pdf", m.str("format") != "mp4" else { continue }
                let kind = MediaLabels.kind(type)
                if ["mixrbv1", "mixrbv2", "box-texture", "support-texture", "video", "video-normalized", "themehs", "bezel-4-3", "bezel-16-9"].contains(type) { continue }
                let clean = Self.redact(url)
                out.append(remote("screenscraper", clean, thumb: clean + "&maxwidth=320&maxheight=320", label: type, kind: kind,
                                  region: m.str("region"), title: "\(type) (\(m.str("region") ?? "?"))", page: IDSpace.link("screenscraper", id),
                                  license: "CC BY-NC-SA 4.0"))
            }
        }
        return out
    }
}

// MARK: Brave image search (paid: only on request)

nonisolated public struct BraveSource: MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    static let keys = ["BRAVE_SEARCH_API_KEY"]

    public var info: SourceInfo {
        get async {
            let missing = ctx.missing(Self.keys)
            return SourceInfo(id: "brave", name: "Brave image search", state: missing.isEmpty ? .ready : .needsKey,
                              note: missing.isEmpty ? "paid per search: only when asked" : ctx.needsKeyNote(missing), homepage: "https://brave.com/search/api/")
        }
    }

    /// Not cached: Brave's terms allow keeping only what's picked.
    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        guard let key = ctx.env["BRAVE_SEARCH_API_KEY"] else { return [] }
        let q = "\(program.title)\(program.year.map { " \($0)" } ?? "") box art"
        let url = URL.make("https://api.search.brave.com/res/v1/images/search", [("q", q), ("count", "40"), ("safesearch", "strict")])
        let j = try await ctx.http.fetch(url, headers: ["X-Subscription-Token": key, "Accept": "application/json"], cache: .none).json() as? JSONObject
        return (j?.arr("results") ?? []).compactMap { r in
            guard let full = r.obj("properties")?.str("url") else { return nil }
            let title = r.str("title")
            return remote("brave", full, thumb: r.obj("thumbnail")?.str("src"), label: title, kind: title.map(MediaLabels.kind),
                          width: r.obj("properties")?.int("width"), height: r.obj("properties")?.int("height"), title: title,
                          page: r.str("url"))
        }
    }
}
