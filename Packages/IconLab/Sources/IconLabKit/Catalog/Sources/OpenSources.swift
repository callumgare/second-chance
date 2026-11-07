import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Sources")

// Keyless JSON sources: PCGamingWiki (MediaWiki; its Cargo API now refuses anonymous queries), Lutris, Steam, GOG,
// the Internet Archive and Openverse.

// MARK: PCGamingWiki

nonisolated public struct PCGamingWikiSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    static let api = "https://www.pcgamingwiki.com/w/api.php"
    public var info: SourceInfo { get async { SourceInfo(id: "pcgamingwiki", name: "PCGamingWiki", state: .ready, homepage: "https://www.pcgamingwiki.com") } }

    public func search(_ query: String) async throws -> [ProgramHit] {
        let json = try await ctx.http.json(.make(Self.api, [("action", "query"), ("format", "json"), ("formatversion", "2"), ("generator", "search"),
                                                            ("gsrsearch", query), ("gsrlimit", "8"), ("gsrnamespace", "0"),
                                                            ("prop", "pageprops|revisions"), ("rvprop", "content"), ("rvslots", "main")]),
                                           cache: .search)
        return Self.parseSearch(json)
    }

    static func parseSearch(_ json: Any) -> [ProgramHit] {
        let pages = ((json as? JSONObject)?.obj("query")?.arr("pages") ?? []).sorted { ($0.int("index") ?? 99) < ($1.int("index") ?? 99) }
        return pages.compactMap { p in
            guard let title = p.str("title") else { return nil }
            let text = p.arr("revisions").first?.obj("slots")?.obj("main")?.str("content") ?? ""
            guard text.contains("{{Infobox game") else { return nil }
            var h = parseInfobox(text, page: title)
            h.thumb = p.obj("pageprops")?.str("image")
            return h
        }
    }

    static func field(_ text: String, _ name: String) -> String? {
        guard let r = text.range(of: "\\|\\s*\(name)\\s*=([^\\n|]*)", options: .regularExpression) else { return nil }
        let v = text[r].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return v.isEmpty ? nil : v
    }

    static func rows(_ text: String, _ kind: String) -> [[String]] {
        let rx: NSRegularExpression
        do {
            rx = try NSRegularExpression(pattern: "\\{\\{Infobox game/row/\(NSRegularExpression.escapedPattern(for: kind))\\|([^}]*)\\}\\}")
        } catch {
            logger.error("PCGamingWiki's infobox pattern for \(kind) doesn't compile: \(error)")
            return []
        }
        return rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { text[$0].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
    }

    static func parseInfobox(_ text: String, page: String) -> ProgramHit {
        let name = page.replacingOccurrences(of: " \\((video game|[0-9]{4})\\)$", with: "", options: .regularExpression)
        var h = ProgramHit(source: "pcgamingwiki", sourceId: page.replacingOccurrences(of: " ", with: "_"), title: name)
        if name != page { h.alternateTitles = [page] }
        let dates = rows(text, "date")
        h.year = dates.compactMap { $0.count > 1 ? firstYear($0[1]) : nil }.min()
        h.platforms = dates.compactMap(\.first)
        h.developer = rows(text, "developer").first?.first
        h.publisher = rows(text, "publisher").first?.first
        if let s = field(text, "steam appid") { h.ids["steam"] = s.replacingOccurrences(of: " ", with: "") }
        if let g = field(text, "gogcom id") { h.ids["gog"] = g.replacingOccurrences(of: " ", with: "") }
        if let l = field(text, "lutris") { h.ids["lutris"] = l }
        if let m = field(text, "mobygames"), Int(m) != nil { h.ids["mobygames"] = m } else if let m = field(text, "mobygames") { h.ids["mobygames-slug"] = m }
        if let w = field(text, "wikipedia") { h.ids["wikipedia"] = w }
        if let w = field(text, "winehq") { h.ids["winehq"] = w }
        if let igdb = rows(text, "reception").first(where: { $0.first == "IGDB" }), igdb.count > 1, !igdb[1].isEmpty, igdb[1] != "link" { h.ids["igdb-slug"] = igdb[1] }
        h.kind = "game"
        h.url = IDSpace.link("pcgamingwiki", page)
        h.tidy()
        return h
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var pages = program.idList("pcgamingwiki")
        if pages.isEmpty {
            pages = try await search(program.title).filter { Titles.normalise($0.title) == Titles.normalise(program.title) }.prefix(1).map(\.sourceId)
        }
        var out: [RemoteMedia] = []
        for page in pages.prefix(2) {
            let json = try await ctx.http.json(.make(Self.api, [("action", "parse"), ("format", "json"), ("formatversion", "2"), ("page", page),
                                                                ("prop", "wikitext"), ("section", "0")]), cache: .api)
            guard let text = (json as? JSONObject)?.obj("parse")?.str("wikitext"), let cover = Self.field(text, "cover") else { continue }
            // its index.php refuses robots; the API gives the file's URLs
            let infos = try await Commons.imageInfo(ctx.http, api: Self.api, titles: ["File:" + cover])
            guard let i = infos["File:" + cover] ?? infos.values.first else { continue }
            out.append(remote("pcgamingwiki", i.url, thumb: i.thumb, label: "cover", width: i.width, height: i.height, title: cover,
                              page: IDSpace.link("pcgamingwiki", page)))
        }
        return out
    }
}

// MARK: Lutris

nonisolated public struct LutrisSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "lutris", name: "Lutris", state: .ready, homepage: "https://lutris.net") } }

    public func search(_ query: String) async throws -> [ProgramHit] {
        let json = try await ctx.http.json(.make("https://lutris.net/api/games", [("search", query)]), cache: .search)
        return ((json as? JSONObject)?.arr("results") ?? []).prefix(20).compactMap(Self.parseGame)
    }

    static func parseGame(_ g: JSONObject) -> ProgramHit? {
        guard let slug = g.str("slug"), let name = g.str("name") else { return nil }
        var h = ProgramHit(source: "lutris", sourceId: slug, title: name)
        h.year = g.int("year")
        h.platforms = g.arr("platforms").compactMap { $0.str("name") }
        h.alternateTitles = g.arr("aliases").compactMap { $0.str("name") }
        for p in g.arr("provider_games") {
            guard let s = p.str("slug") else { continue }
            switch p.str("service") {
            case "igdb": h.ids["igdb-slug"] = s
            case "steam": h.ids["steam"] = s
            case "gog": h.ids["gog-slug"] = s
            default: break
            }
        }
        h.thumb = g.str("coverart") ?? g.str("banner_url")
        h.kind = "game"
        h.url = IDSpace.link("lutris", slug)
        h.tidy()
        return h
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var slugs = program.idList("lutris")
        if slugs.isEmpty {
            slugs = try await search(program.title).filter { Titles.normalise($0.title) == Titles.normalise(program.title) }.prefix(1).map(\.sourceId)
        }
        var out: [RemoteMedia] = []
        for slug in slugs.prefix(2) {
            guard let g = try await ctx.http.json(URL.required("https://lutris.net/api/games/\(slug)"), cache: .api) as? JSONObject else { continue }
            let page = IDSpace.link("lutris", slug)
            if let c = g.str("coverart") { out.append(remote("lutris", c.replacingOccurrences(of: "/cover_big/", with: "/cover_big/"), label: "cover", page: page)) }
            if let b = g.str("banner_url") { out.append(remote("lutris", b, label: "banner", page: page)) }
            if let i = g.str("icon_url") { out.append(remote("lutris", i, label: "icon", page: page)) }
        }
        return out
    }
}

// MARK: Steam

nonisolated public struct SteamSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "steam", name: "Steam", state: .ready, note: "re-releases", homepage: "https://store.steampowered.com") } }

    public func search(_ query: String) async throws -> [ProgramHit] {
        let json = try await ctx.http.json(.make("https://store.steampowered.com/api/storesearch/", [("term", query), ("l", "english"), ("cc", "US")]), cache: .search)
        return Self.parseSearch(json)
    }

    static func parseSearch(_ json: Any) -> [ProgramHit] {
        ((json as? JSONObject)?.arr("items") ?? []).compactMap { i in
            guard i.str("type") == "app", let id = i.str("id"), let name = i.str("name") else { return nil }
            var h = ProgramHit(source: "steam", sourceId: id, title: name)
            let p = i.obj("platforms") ?? [:]
            h.platforms = [("windows", "Windows"), ("mac", "Mac OS X"), ("linux", "Linux")].compactMap { (p[$0.0] as? Bool) == true ? $0.1 : nil }
            h.thumb = i.str("tiny_image")
            h.kind = name.lowercased().contains("soundtrack") ? "expansion" : "game"
            h.url = IDSpace.link("steam", id)
            h.tidy()
            return h
        }
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var out: [RemoteMedia] = []
        for id in program.idList("steam").prefix(3) {
            let base = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)"
            let page = IDSpace.link("steam", id)
            out.append(remote("steam", "\(base)/library_600x900_2x.jpg", thumb: "\(base)/library_600x900.jpg", label: "library capsule",
                              width: 1200, height: 1800, title: "Library capsule", page: page))
            out.append(remote("steam", "\(base)/logo.png", label: "logo", title: "Logo", page: page))
            out.append(remote("steam", "\(base)/library_hero.jpg", label: "library hero", width: 3840, height: 1240, title: "Library hero", page: page))
            guard let j = try? await ctx.http.json(.make("https://store.steampowered.com/api/appdetails", [("appids", id), ("l", "english")]), cache: .api) as? JSONObject,
                  let d = j.obj(id)?.obj("data") else { continue }
            if let hdr = d.str("header_image") { out.append(remote("steam", hdr, label: "header", width: 460, height: 215, title: "Header", page: page)) }
            for s in d.arr("screenshots").prefix(5) {
                if let full = s.str("path_full") { out.append(remote("steam", full, thumb: s.str("path_thumbnail"), label: "screenshot", title: "Screenshot", page: page)) }
            }
        }
        return out
    }
}

// MARK: GOG

nonisolated public struct GOGSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "gog", name: "GOG", state: .ready, note: "re-releases", homepage: "https://www.gog.com") } }

    func catalog(_ query: String) async throws -> [JSONObject] {
        let json = try await ctx.http.json(.make("https://catalog.gog.com/v1/catalog", [("query", "like:\(query)"), ("limit", "12"), ("order", "desc:score")]), cache: .search)
        return (json as? JSONObject)?.arr("products") ?? []
    }

    public func search(_ query: String) async throws -> [ProgramHit] {
        try await catalog(query).compactMap(Self.parseProduct).filter { Titles.similarity(query, $0.title) > 0 }
    }

    static func parseProduct(_ p: JSONObject) -> ProgramHit? {
        guard let id = p.str("id"), let title = p.str("title") else { return nil }
        var h = ProgramHit(source: "gog", sourceId: id, title: title)
        h.year = firstYear(p.str("releaseDate"))
        h.developer = p.strings("developers").first
        h.publisher = p.strings("publishers").first
        h.platforms = p.strings("operatingSystems").map { ["windows": "Windows", "osx": "Mac OS X", "linux": "Linux"][$0] ?? $0 }
        if let slug = p.str("slug") { h.ids["gog-slug"] = "game/\(slug)" }
        h.thumb = p.str("coverVertical") ?? p.str("coverHorizontal")
        h.kind = p.str("productType") == "dlc" ? "expansion" : "game"
        h.url = p.str("storeLink")
        h.tidy()
        return h
    }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        let ids = Set(program.idList("gog"))
        let all = try await catalog(program.title)
        var products = all.filter { p in p.str("id").map(ids.contains) ?? false }
        if ids.isEmpty {
            // not linked: the same program by title, either from its year or as an edition of it ("Myst: Masterpiece
            // Edition"), but not the same title years later (that's a remake: "Myst" 2021)
            products = all.filter { p in
                let t = p.str("title") ?? ""
                guard Titles.base(t) == Titles.base(program.title) else { return false }
                guard let py = program.year, let y = firstYear(p.str("releaseDate")) else { return true }
                return abs(y - py) <= 1 || Titles.normalise(t) != Titles.normalise(program.title)
            }.prefix(1).map { $0 }
        }
        var out: [RemoteMedia] = []
        for p in products.prefix(2) {
            let page = p.str("storeLink")
            if let c = p.str("coverVertical") { out.append(remote("gog", c, label: "cover", title: "Cover", page: page)) }
            if let c = p.str("coverHorizontal") { out.append(remote("gog", c, label: "header", title: "Wide cover", page: page)) }
            if let l = p.str("logo") { out.append(remote("gog", l, label: "logo", title: "Logo", page: page)) }
            if let b = p.str("galaxyBackgroundImage") { out.append(remote("gog", b, label: "background", title: "Background", page: page)) }
            for s in p.strings("screenshots").prefix(4) {
                out.append(remote("gog", s.replacingOccurrences(of: "{formatter}", with: "ggvgl_2x"),
                                  thumb: s.replacingOccurrences(of: "{formatter}", with: "product_card_v2_thumbnail_271"), label: "screenshot",
                                  title: "Screenshot", page: page))
            }
        }
        return out
    }
}

// MARK: Internet Archive

nonisolated public struct InternetArchiveSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "internetarchive", name: "Internet Archive", state: .ready, note: "one request every 4 s", homepage: "https://archive.org") } }

    public func search(_ query: String) async throws -> [ProgramHit] {
        let words = Titles.tokens(query, keepStopwords: true).map { $0.replacingOccurrences(of: "\"", with: "") }
        guard !words.isEmpty else { return [] }
        let q = "title:(\(words.joined(separator: " AND "))) AND mediatype:(software OR image)"
        let url = URL.make("https://archive.org/advancedsearch.php", [("q", q), ("fl[]", "identifier"), ("fl[]", "title"), ("fl[]", "year"),
                                                                      ("fl[]", "creator"), ("fl[]", "mediatype"), ("rows", "15"),
                                                                      ("sort[]", "downloads desc"), ("output", "json")])
        return Self.parseSearch(try await ctx.http.json(url, cache: .search))
    }

    static func parseSearch(_ json: Any) -> [ProgramHit] {
        ((json as? JSONObject)?.obj("response")?.arr("docs") ?? []).compactMap { d in
            guard let id = d.str("identifier"), let title = d.str("title") else { return nil }
            var h = ProgramHit(source: "internetarchive", sourceId: id, title: title)
            h.year = d.int("year") ?? firstYear(d.str("year"))
            h.summary = (d["creator"] as? String) ?? (d["creator"] as? [String])?.joined(separator: ", ")
            h.kind = d.str("mediatype") == "software" ? "software" : nil
            h.thumb = "https://archive.org/services/img/\(id)"
            h.url = IDSpace.link("internetarchive", id)
            h.tidy()
            return h
        }
    }

    static let imageFormats: Set<String> = ["JPEG", "PNG", "GIF", "Animated GIF", "BMP", "JPEG 2000"]

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var items = program.idList("internetarchive")
        if items.isEmpty {
            items = try await search(program.title).filter { Titles.base($0.title) == Titles.base(program.title) }.map(\.sourceId)
        }
        var out: [RemoteMedia] = []
        for id in items.prefix(5) {
            guard let j = try await ctx.http.json(URL.required("https://archive.org/metadata/\(id)"), cache: .api) as? JSONObject else { continue }
            out += Self.parseFiles(j, item: id)
        }
        return out
    }

    /// An item's pictures: originals (and the thumbnails archive.org made of them), named scans first.
    static func parseFiles(_ j: JSONObject, item: String) -> [RemoteMedia] {
        let files = j.arr("files")
        var thumbs: [String: String] = [:]
        for f in files where f.str("format") == "Thumbnail" || f.str("format") == "JPEG Thumb" {
            if let n = f.str("name"), let orig = f.str("original") { thumbs[orig] = n }
        }
        let server = "https://archive.org/download/\(item)/"
        func enc(_ n: String) -> String {
            n.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .pathSegment) ?? String($0) }.joined(separator: "/")
        }
        var out: [RemoteMedia] = []
        for f in files {
            guard let name = f.str("name"), let format = f.str("format"), imageFormats.contains(format), f.str("source") == "original",
                  !name.hasPrefix("__ia_thumb"), (f.int("size") ?? 0) < 40_000_000 else { continue }
            let label = (name as NSString).lastPathComponent
            out.append(remote("internetarchive", server + enc(name), thumb: thumbs[name].map { server + enc($0) }, label: label,
                              kind: MediaLabels.kind(label), width: f.int("width"), height: f.int("height"), title: label,
                              page: "https://archive.org/details/\(item)"))
        }
        // named scans first, then the rest; at most 15 an item
        let named = out.filter { $0.kind != "other" }, rest = out.filter { $0.kind == "other" }
        var picked = Array((named + rest).prefix(15))
        if picked.isEmpty {
            picked = [remote("internetarchive", "https://archive.org/services/img/\(item)", label: "item thumbnail", kind: "other",
                             title: "Item thumbnail", page: "https://archive.org/details/\(item)")]
        }
        return picked
    }
}

// MARK: Openverse

nonisolated public struct OpenverseSource: MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "openverse", name: "Openverse", state: .ready, note: "openly licensed photos", homepage: "https://openverse.org") } }

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        func search(_ q: String) async throws -> [JSONObject] {
            let json = try await ctx.http.json(.make("https://api.openverse.org/v1/images/", [("q", q), ("page_size", "20"), ("mature", "false")]),
                                               cache: .search)
            return (json as? JSONObject)?.arr("results") ?? []
        }
        // The title as it is, and the title as a game: both kept, the second's ranked higher.
        let general = try await search(program.title)
        let specific = (try? await search("\(program.title) game")) ?? []
        let specificUrls = Set(specific.compactMap { $0.str("url") })
        let toks = Set(Titles.tokens(program.title))
        var seen = Set<String>(), out: [RemoteMedia] = []
        for r in specific + general {
            guard let url = r.str("url"), let title = r.str("title"), seen.insert(url).inserted else { continue }
            // Openverse matches loosely ("Myst" finds misty mornings): keep only pictures whose title or tags name it
            let tags = (r["tags"] as? [JSONObject] ?? []).compactMap { $0.str("name") }.joined(separator: " ")
            guard toks.isSubset(of: Set(Titles.tokens(title + " " + tags))) else { continue }
            let lic = [r.str("license"), r.str("license_version")].compactMap { $0 }.joined(separator: " ")
            var m = remote("openverse", url, thumb: r.str("thumbnail"), label: title, kind: MediaLabels.kind(title), width: r.int("width"),
                           height: r.int("height"), title: title, page: r.str("foreign_landing_url"), license: lic.isEmpty ? nil : "CC " + lic.uppercased())
            m.relevance = Relevance.score(title + " " + tags, identity: program, specific: specificUrls.contains(url))
            out.append(m)
        }
        return out
    }
}
