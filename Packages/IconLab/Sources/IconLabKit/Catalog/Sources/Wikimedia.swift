import Foundation

// Wikidata (the merge hub: every other source's id for an item), Wikipedia (the infobox picture and the page's
// files) and Wikimedia Commons (logos, the item's category).

nonisolated public struct WikidataSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "wikidata", name: "Wikidata", state: .ready, note: "links IDs", homepage: "https://www.wikidata.org") } }

    static let api = "https://www.wikidata.org/w/api.php"
    static let sparql = "https://query.wikidata.org/sparql"

    public func search(_ query: String) async throws -> [ProgramHit] {
        async let prefix = ctx.http.json(.make(Self.api, [("action", "wbsearchentities"), ("search", query), ("language", "en"), ("type", "item"),
                                                          ("limit", "12"), ("format", "json")]), cache: .search)
        async let full = ctx.http.json(.make(Self.api, [("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", "12"),
                                                        ("srprop", ""), ("format", "json")]), cache: .search)
        var qids: [String] = []
        if let p = try? await prefix as? JSONObject { qids += p.arr("search").compactMap { $0.str("id") } }
        if let f = try? await full as? JSONObject { qids += (f.obj("query")?.arr("search") ?? []).compactMap { $0.str("title") } }
        var seen = Set<String>()
        qids = qids.filter { $0.hasPrefix("Q") && seen.insert($0).inserted }
        return try await details(Array(qids.prefix(20)))
    }

    /// The program items among `qids`, with every id Wikidata has for each.
    public func details(_ qids: [String]) async throws -> [ProgramHit] {
        guard !qids.isEmpty else { return [] }
        let props = IDSpace.all.compactMap { s in s.wikidata.map { "(\"\(s.key)\" wdt:\($0))" } }
            + ["(\"image\" wdt:P18)", "(\"logo\" wdt:P154)", "(\"icon\" wdt:P8972)"]
        let q = """
        SELECT ?item ?itemLabel ?itemDescription ?p ?v WHERE {
          VALUES ?item { \(qids.map { "wd:\($0)" }.joined(separator: " ")) }
          { VALUES ?p { "date" } ?item wdt:P577 ?v } UNION
          { VALUES ?p { "inception" } ?item wdt:P571 ?v } UNION
          { VALUES ?p { "platform" } ?item wdt:P400 ?x . ?x rdfs:label ?v FILTER(lang(?v) = "en") } UNION
          { VALUES ?p { "os" } ?item wdt:P306 ?x . ?x rdfs:label ?v FILTER(lang(?v) = "en") } UNION
          { VALUES ?p { "developer" } ?item wdt:P178 ?x . ?x rdfs:label ?v FILTER(lang(?v) = "en") } UNION
          { VALUES ?p { "publisher" } ?item wdt:P123 ?x . ?x rdfs:label ?v FILTER(lang(?v) = "en") } UNION
          { VALUES ?p { "alias" } ?item skos:altLabel ?v FILTER(lang(?v) = "en") } UNION
          { VALUES ?p { "isgame" } ?item wdt:P31/wdt:P279* wd:Q7889 BIND("1" AS ?v) } UNION
          { VALUES ?p { "issoftware" } ?item wdt:P31/wdt:P279* wd:Q7397 BIND("1" AS ?v) } UNION
          { VALUES ?p { "isseries" } ?item wdt:P31/wdt:P279* wd:Q7058673 BIND("1" AS ?v) } UNION
          { VALUES ?p { "enwiki" } ?a schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> ; schema:name ?v } UNION
          { VALUES (?p ?prop) { \(props.joined(separator: " ")) } ?item ?prop ?v }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        """
        let body = "query=\(q.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? "")"
        let json = try await ctx.http.json(URL.required(Self.sparql), method: "POST",
                                           headers: ["Accept": "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded"],
                                           body: Data(body.utf8), cache: .search)
        return Self.parseDetails(json, order: qids)
    }

    static func parseDetails(_ json: Any, order: [String]) -> [ProgramHit] {
        let rows = ((json as? JSONObject)?.obj("results")?.arr("bindings")) ?? []
        var byItem: [String: (label: String, desc: String?, props: [String: [String]])] = [:]
        for b in rows {
            guard let item = b.obj("item")?.str("value")?.components(separatedBy: "/").last,
                  let p = b.obj("p")?.str("value"), let v = b.obj("v")?.str("value") else { continue }
            var e = byItem[item] ?? (b.obj("itemLabel")?.str("value") ?? item, b.obj("itemDescription")?.str("value"), [:])
            if !(e.props[p] ?? []).contains(v) { e.props[p, default: []].append(v) }
            byItem[item] = e
        }
        var out: [ProgramHit] = []
        for qid in order {
            guard let e = byItem[qid], e.label != qid else { continue }
            let isGame = e.props["isgame"] != nil, isSoftware = e.props["issoftware"] != nil
            guard isGame || isSoftware, e.props["isseries"] == nil else { continue }
            var h = ProgramHit(source: "wikidata", sourceId: qid, title: e.label)
            h.summary = e.desc
            let dates = (e.props["date"] ?? []) + (e.props["inception"] ?? [])
            h.year = dates.compactMap(firstYear).min() ?? firstYear(e.desc)
            h.platforms = (e.props["platform"] ?? []) + (e.props["os"] ?? [])
            h.developer = e.props["developer"]?.first
            h.publisher = e.props["publisher"]?.first
            h.alternateTitles = e.props["alias"] ?? []
            h.kind = isGame ? "game" : "software"
            h.url = "https://www.wikidata.org/wiki/\(qid)"
            for s in IDSpace.all where s.wikidata != nil {
                if let vs = e.props[s.key] { h.ids[s.key] = vs.joined(separator: ",") }
            }
            if let w = e.props["enwiki"]?.first { h.ids["wikipedia"] = w }
            if let f = (e.props["logo"] ?? e.props["icon"] ?? e.props["image"])?.first { h.thumb = Self.commonsThumb(f) }
            h.tidy()
            out.append(h)
        }
        return out
    }

    /// A Commons file (as Wikidata gives it: a Special:FilePath URL) at `width`.
    static func commonsThumb(_ fileURL: String, width: Int = 240) -> String {
        fileURL.replacingOccurrences(of: "http://", with: "https://") + "?width=\(width)"
    }

    /// Wikidata items that have any of these hits' ids (or their Wikipedia pages): the hub for hits the search
    /// didn't find through Wikidata. Returns the items' hits (with every id they have).
    public func enrich(_ hits: [ProgramHit], known: Set<String>) async throws -> [ProgramHit] {
        var pairs: [String] = [], articles: [String] = []
        var seen = Set<String>()
        for h in hits where h.source != "wikidata" {
            var ids = h.ids
            if IDSpace.byKey[h.source] != nil { ids[h.source] = ([h.sourceId] + IDSpace.split(ids[h.source])).joined(separator: ",") }
            for (k, v) in ids {
                for one in IDSpace.split(v) {
                    if k == "wikidata", one.hasPrefix("Q"), !known.contains(one) {
                        if seen.insert("Q" + one).inserted { pairs.append("Q:\(one)") }
                    } else if k == "wikipedia" {
                        if seen.insert("w:" + one).inserted { articles.append(one) }
                    } else if let p = IDSpace.byKey[k]?.wikidata, !IDSpace.notIdentifying.contains(k), seen.insert("\(p):\(one)").inserted {
                        pairs.append("(wdt:\(p) \"\(one.replacingOccurrences(of: "\"", with: "\\\""))\")")
                    }
                }
            }
        }
        let direct = pairs.filter { $0.hasPrefix("Q:") }.map { String($0.dropFirst(2)) }
        let props = pairs.filter { !$0.hasPrefix("Q:") }.prefix(160)
        let arts = articles.prefix(60).map { "<\(Self.articleIRI($0))>" }
        var qids = direct
        if !props.isEmpty || !arts.isEmpty {
            var parts: [String] = []
            if !props.isEmpty { parts.append("{ VALUES (?prop ?v) { \(props.joined(separator: " ")) } ?item ?prop ?v }") }
            if !arts.isEmpty { parts.append("{ VALUES ?article { \(arts.joined(separator: " ")) } ?article schema:about ?item }") }
            let q = "SELECT DISTINCT ?item WHERE { \(parts.joined(separator: " UNION ")) } LIMIT 200"
            let body = "query=\(q.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? "")"
            let json = try await ctx.http.json(URL.required(Self.sparql), method: "POST",
                                               headers: ["Accept": "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded"],
                                               body: Data(body.utf8), cache: .search)
            for b in ((json as? JSONObject)?.obj("results")?.arr("bindings")) ?? [] {
                if let q = b.obj("item")?.str("value")?.components(separatedBy: "/").last { qids.append(q) }
            }
        }
        var s2 = Set<String>()
        qids = qids.filter { !known.contains($0) && s2.insert($0).inserted }
        guard !qids.isEmpty else { return [] }
        var out: [ProgramHit] = []
        for chunk in stride(from: 0, to: min(qids.count, 60), by: 20) {
            out += try await details(Array(qids[chunk..<min(chunk + 20, qids.count)]))
        }
        return out
    }

    /// The IRI Wikidata uses for an English Wikipedia article (MediaWiki's own URL encoding).
    static func articleIRI(_ title: String) -> String {
        let allowed = CharacterSet.asciiAlphanumerics.union(CharacterSet(charactersIn: "-_.~;@$!*(),/:"))
        let t = title.replacingOccurrences(of: " ", with: "_")
        return "https://en.wikipedia.org/wiki/" + (t.addingPercentEncoding(withAllowedCharacters: allowed) ?? t)
    }

    // MARK: Media: the item's logo (P154), icon (P8972) and image (P18)

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        let qids = Array(program.idList("wikidata").prefix(3))
        guard !qids.isEmpty else { return [] }
        let q = """
        SELECT ?item ?p ?f WHERE { VALUES ?item { \(qids.map { "wd:\($0)" }.joined(separator: " ")) }
          VALUES (?p ?prop) { ("logo" wdt:P154) ("icon" wdt:P8972) ("image" wdt:P18) } ?item ?prop ?f }
        """
        let body = "query=\(q.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? "")"
        let json = try await ctx.http.json(URL.required(Self.sparql), method: "POST",
                                           headers: ["Accept": "application/sparql-results+json", "Content-Type": "application/x-www-form-urlencoded"],
                                           body: Data(body.utf8), cache: .api)
        var files: [(String, String)] = []
        for b in ((json as? JSONObject)?.obj("results")?.arr("bindings")) ?? [] {
            guard let p = b.obj("p")?.str("value"), let f = b.obj("f")?.str("value")?.components(separatedBy: "/Special:FilePath/").last,
                  let name = f.removingPercentEncoding else { continue }
            files.append((p, name))
        }
        let infos = try await Commons.imageInfo(ctx.http, api: Commons.api, titles: files.map { "File:" + $0.1 })
        return files.compactMap { p, name in
            guard let i = infos["File:" + name] ?? infos["File:" + name.replacingOccurrences(of: "_", with: " ")] else { return nil }
            let label = ["logo": "Logo (P154)", "icon": "Icon (P8972)", "image": "Image (P18)"][p] ?? p
            let kind = p == "logo" ? "logo" : p == "icon" ? "icon" : MediaLabels.kind(name)
            return remote("wikidata", i.url, thumb: i.thumb, label: label, kind: kind, width: i.width, height: i.height, title: name,
                          page: i.page, license: i.license)
        }
    }
}

nonisolated public struct WikipediaSource: ProgramSource, MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "wikipedia", name: "Wikipedia", state: .ready, homepage: "https://en.wikipedia.org") } }
    static let api = "https://en.wikipedia.org/w/api.php"

    static let programWords = ["video game", "computer game", "game", "software", "program", "application", "editor", "utility",
                               "operating system", "browser", "word processor", "spreadsheet", "educational", "edutainment", "screensaver",
                               "simulator", "interactive", "cd-rom", "hypermedia", "authoring", "paint", "system for apple", "drawing"]
    static let notProgramWords = ["series", "franchise", "developer", "company", "publisher", "novel", "book", "film", "television", "album",
                                  "song", "character", "person", "actress", "actor", "musician", "band", "magazine", "list of", "disambiguation",
                                  "manga", "anime", "comic", "board game", "card game", "tabletop", "role-playing game system", "studio", "village",
                                  "city", "river", "island"]

    public func search(_ query: String) async throws -> [ProgramHit] {
        let json = try await ctx.http.json(.make(Self.api, [("action", "query"), ("format", "json"), ("formatversion", "2"),
                                                            ("generator", "search"), ("gsrsearch", query), ("gsrlimit", "15"),
                                                            ("prop", "pageprops|pageimages|description"), ("piprop", "thumbnail"),
                                                            ("pithumbsize", "240"), ("pilicense", "any"), ("ppprop", "wikibase_item|disambiguation")]),
                                           cache: .search)
        return Self.parseSearch(json)
    }

    static func parseSearch(_ json: Any) -> [ProgramHit] {
        let pages = ((json as? JSONObject)?.obj("query")?.arr("pages") ?? []).sorted { ($0.int("index") ?? 99) < ($1.int("index") ?? 99) }
        var out: [ProgramHit] = []
        for p in pages {
            guard let title = p.str("title"), p.obj("pageprops")?["disambiguation"] == nil else { continue }
            let desc = p.str("description")?.lowercased() ?? ""
            guard programWords.contains(where: { desc.contains($0) }), !notProgramWords.contains(where: { desc.contains($0) }) else { continue }
            let bare = title.replacingOccurrences(of: " \\((video game|software|computer game|[0-9]{4} video game)\\)$", with: "", options: .regularExpression)
            var h = ProgramHit(source: "wikipedia", sourceId: title, title: bare)
            h.summary = p.str("description")
            h.year = firstYear(desc)
            h.kind = desc.contains("game") && !desc.contains("game engine") && !desc.contains("game creation") ? "game" : "software"
            if let q = p.obj("pageprops")?.str("wikibase_item") { h.ids["wikidata"] = q }
            h.thumb = p.obj("thumbnail")?.str("source")
            h.url = IDSpace.link("wikipedia", title)
            if h.title != title { h.alternateTitles = [title] }
            h.tidy()
            out.append(h)
        }
        return out
    }

    // MARK: Media: the files the article uses (cover, logo, screenshots)

    static let junk = ["commons-logo", "wikiquote", "wiktionary", "wikibooks", "question_book", "question book", "edit-clear", "ambox", "folder",
                       "lock-", "oojs", "crystal", "nuvola", "gnome-", "padlock", "text document", "flag of", "flag_of", "symbol ", "icon-",
                       "p vip", "portal", "wikidata", "increase", "decrease", "steady", "star full", "star empty", "star half", "red pencil",
                       "office-book", "magnify", "disambig", "speakerlink", "sound-icon", "video-x-generic", "loudspeaker", "people icon",
                       "emblem-", "ambox", "pog.svg", "wpvg", "wikiproject", "cscr-", "featured", "symbol support", "symbol oppose", "info icon",
                       "searchtool", "audio a", "joystick", "gamepad", "video game controller", "videogame"]

    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        var title = program.idList("wikipedia").first
        if title == nil {
            let hits = try await search(program.title + (program.year.map { " \($0)" } ?? ""))
            title = hits.first { Titles.similarity(program.title, $0.title) >= 0.85 }?.sourceId
        }
        guard let title else { return [] }
        let json = try await ctx.http.json(.make(Self.api, [("action", "query"), ("format", "json"), ("formatversion", "2"), ("titles", title),
                                                            ("redirects", "1"), ("generator", "images"), ("gimlimit", "60"), ("prop", "imageinfo"),
                                                            ("iiprop", "url|size|mime|extmetadata"), ("iiextmetadatafilter", "LicenseShortName"),
                                                            ("iiurlwidth", "320")]), cache: .api)
        let page = IDSpace.link("wikipedia", title)
        return Commons.parseImageInfo(json).compactMap { name, i in
            let lower = name.lowercased()
            guard !Self.junk.contains(where: { lower.contains($0) }), max(i.width ?? 0, i.height ?? 0) >= 120 else { return nil }
            let clean = name.replacingOccurrences(of: "File:", with: "")
            return remote("wikipedia", i.url, thumb: i.thumb, label: clean, kind: MediaLabels.kind(clean), width: i.width, height: i.height,
                          title: clean, page: page, license: i.license)
        }
    }
}

nonisolated public struct CommonsSource: MediaSource {
    let ctx: SourceContext
    public init(_ ctx: SourceContext) { self.ctx = ctx }
    public var info: SourceInfo { get async { SourceInfo(id: "commons", name: "Wikimedia Commons", state: .ready, homepage: "https://commons.wikimedia.org") } }

    /// The item's Commons category (Wikidata P373), else a file search for the title.
    public func media(for program: ProgramIdentity) async throws -> [RemoteMedia] {
        let base: [(String, String)] = [("action", "query"), ("format", "json"), ("formatversion", "2"), ("prop", "imageinfo"),
                                        ("iiprop", "url|size|mime|extmetadata"), ("iiextmetadatafilter", "LicenseShortName|ImageDescription|Categories|ObjectName"),
                                        ("iiurlwidth", "320")]
        // The item's own category is about the program: everything in it counts.
        if let cat = program.idList("commonscat").first {
            let json = try await ctx.http.json(.make(Commons.api, base + [("generator", "categorymembers"), ("gcmtitle", "Category:" + cat),
                                                                          ("gcmtype", "file"), ("gcmlimit", "40")]), cache: .api)
            return Commons.parseImageInfo(json).compactMap { name, i in make(name, i, program, specific: true, category: true) }
        }
        // Otherwise two searches: the title as it is (a rare program may have little else), and the title with what
        // makes it a game; pictures from both are kept, the second's ranked higher.
        func search(_ q: String) async throws -> [(String, Commons.Info)] {
            let json = try await ctx.http.json(.make(Commons.api, base + [("generator", "search"), ("gsrnamespace", "6"),
                                                                          ("gsrsearch", q), ("gsrlimit", "20")]), cache: .api)
            return Commons.parseImageInfo(json)
        }
        let makers = [program.developer, program.publisher].compactMap { $0 }.map { "\"\($0)\"" }
        let specificTerms = (["\"video game\"", "\"computer game\"", "CD-ROM", "software"] + makers).joined(separator: " OR ")
        let general = try await search("\"\(program.title)\" filetype:bitmap|drawing")
        let specific = (try? await search("\"\(program.title)\" (\(specificTerms)) filetype:bitmap|drawing")) ?? []
        let specificNames = Set(specific.map(\.0))
        var seen = Set<String>(), out: [RemoteMedia] = []
        for (name, i) in specific + general where seen.insert(name).inserted {
            if let m = make(name, i, program, specific: specificNames.contains(name), category: false) { out.append(m) }
        }
        return out
    }

    func make(_ name: String, _ i: Commons.Info, _ program: ProgramIdentity, specific: Bool, category: Bool) -> RemoteMedia? {
        let clean = name.replacingOccurrences(of: "File:", with: "")
        let titleToks = Set(Titles.tokens(program.title))
        if !category, Set(Titles.tokens(clean + " " + (i.description ?? ""))).intersection(titleToks).count < max(1, titleToks.count - 1) { return nil }
        guard max(i.width ?? 0, i.height ?? 0) >= 120, i.mime?.hasPrefix("image/") != false else { return nil }
        var m = remote("commons", i.url, thumb: i.thumb, label: clean, kind: MediaLabels.kind(clean), width: i.width, height: i.height,
                       title: clean, page: i.page, license: i.license)
        if !category {
            m.relevance = Relevance.score([clean, i.description ?? "", i.categories ?? ""].joined(separator: " "), identity: program, specific: specific)
        }
        return m
    }
}

nonisolated enum Commons {
    static let api = "https://commons.wikimedia.org/w/api.php"

    struct Info {
        var url: String; var thumb: String?; var width: Int?; var height: Int?; var mime: String?; var page: String?; var license: String?
        var description: String?; var categories: String?
    }

    /// File title → its info, from a query with `prop=imageinfo` (formatversion 2). An SVG's "full" copy is a large
    /// PNG rendering.
    static func parseImageInfo(_ json: Any) -> [(String, Info)] {
        let pages = (json as? JSONObject)?.obj("query")?.arr("pages") ?? []
        return pages.compactMap { p in
            guard let title = p.str("title"), let ii = p.arr("imageinfo").first, var url = ii.str("url") else { return nil }
            let mime = ii.str("mime")
            var w = ii.int("width"), h = ii.int("height")
            let thumb = ii.str("thumburl")
            if mime == "image/svg+xml", let t = thumb {
                url = t.replacingOccurrences(of: "/320px-", with: "/1024px-")
                if let ww = w, let hh = h, ww > 0 { h = Int(Double(hh) * 1024 / Double(ww)); w = 1024 }
            }
            guard let mime, mime.hasPrefix("image/"), !mime.contains("tiff"), !mime.contains("djvu") || thumb != nil else { return nil }
            if mime.contains("djvu") || mime.contains("pdf") { url = thumb ?? url }
            let meta = ii.obj("extmetadata")
            let license = meta?.obj("LicenseShortName")?.str("value")
            // descriptions come as HTML: keep the words
            let desc = [meta?.obj("ImageDescription")?.str("value"), meta?.obj("ObjectName")?.str("value")].compactMap { $0 }.joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            return (title, Info(url: url, thumb: thumb, width: w, height: h, mime: mime, page: ii.str("descriptionurl"), license: license,
                                description: desc.isEmpty ? nil : String(desc.prefix(600)), categories: meta?.obj("Categories")?.str("value")))
        }
    }

    static func imageInfo(_ http: HTTP, api: String, titles: [String]) async throws -> [String: Info] {
        guard !titles.isEmpty else { return [:] }
        let json = try await http.json(.make(api, [("action", "query"), ("format", "json"), ("formatversion", "2"),
                                                   ("titles", titles.prefix(40).joined(separator: "|")), ("prop", "imageinfo"),
                                                   ("iiprop", "url|size|mime|extmetadata"), ("iiextmetadatafilter", "LicenseShortName"),
                                                   ("iiurlwidth", "320")]), cache: .api)
        var out: [String: Info] = [:]
        for (t, i) in parseImageInfo(json) { out[t] = i; out[t.replacingOccurrences(of: " ", with: "_")] = i }
        // the API normalises titles ("File:Foo_bar.png" → "File:Foo bar.png"); map the originals too
        for n in (json as? JSONObject)?.obj("query")?.arr("normalized") ?? [] {
            if let from = n.str("from"), let to = n.str("to"), let i = out[to] { out[from] = i }
        }
        return out
    }
}
