import Foundation

// Merging hits into programs and ranking them. Pure: tests drive it with hand-made hits.
//
// 1. Hits that share an id (their own, or one a source knows of another's — Wikidata knows most) are the same
//    program, through a union-find over (namespace, id).
// 2. The rest merge loosely: a shared title form, years within one (three when the titles match exactly and the
//    developer agrees), a compatible platform, and no conflicting developer.
// 3. Neither step joins two clusters that hold different ids from one source — an original and its remaster —
//    except sources that list a program once per platform (LaunchBox's Windows and Mac releases), and the Internet
//    Archive, which has many items per program.

nonisolated public struct SourcePolicy: Sendable {
    public var priority: Int           // lower: preferred for the title and facts
    public var perPlatform = false     // one entry per platform release
    public var many = false            // many entries per program (archive items)
    public var weakYear = false        // its year is often an upload or store date
    public var media = false           // it has pictures to gather

    public static let table: [String: SourcePolicy] = [
        "wikidata": .init(priority: 0, media: true),
        "wikipedia": .init(priority: 1, media: true),
        "launchbox": .init(priority: 2, perPlatform: true, media: true),
        "igdb": .init(priority: 3, media: true),
        "pcgamingwiki": .init(priority: 4, media: true),
        "thegamesdb": .init(priority: 5, perPlatform: true, media: true),
        "screenscraper": .init(priority: 5, perPlatform: true, media: true),
        "lutris": .init(priority: 6, media: true),
        "gog": .init(priority: 7, weakYear: false, media: true),
        "myabandonware": .init(priority: 8, media: true),
        "winworld": .init(priority: 8, media: true),
        "macintoshrepository": .init(priority: 8, media: true),
        "steamgriddb": .init(priority: 9, weakYear: true, media: true),
        "steam": .init(priority: 9, weakYear: true, media: true),
        "internetarchive": .init(priority: 10, many: true, weakYear: true, media: true),
    ]

    public static func of(_ source: String) -> SourcePolicy { table[source] ?? .init(priority: 20) }
}

nonisolated public enum Merger {
    struct Cluster {
        var hits: [ProgramHit] = []
        var ids: [String: Set<String>] = [:]
        var reasons: [String] = []
        // cached for loose matching
        var variants: Set<String> = []
        var normalised: Set<String> = []
        var bases: Set<String> = []
        var cores: Set<String> = []
        var years: [Int] = []            // from sources whose years are reliable
        var families: Set<String> = []
        var developers: [String] = []   // developers and publishers: sources mix them up

        init(_ h: ProgramHit) {
            hits = [h]
            ids = Merger.ids(of: h)
            let titles = [h.title] + h.alternateTitles
            variants = Set(titles.flatMap(Titles.variants))
            normalised = Set(titles.map(Titles.normalise))
            bases = Set(titles.map(Titles.base))
            cores = Set(titles.map(Titles.core))
            if let y = h.year, !SourcePolicy.of(h.source).weakYear { years = [y] }
            families = Set(h.platforms.map(Platforms.family))
            developers = [h.developer, h.publisher].compactMap { $0 }
        }

        mutating func absorb(_ o: Cluster, reason: String) {
            hits += o.hits
            for (k, v) in o.ids { ids[k, default: []].formUnion(v) }
            reasons += o.reasons + [reason]
            variants.formUnion(o.variants); normalised.formUnion(o.normalised); bases.formUnion(o.bases); cores.formUnion(o.cores)
            years += o.years; families.formUnion(o.families); developers += o.developers
        }
    }

    /// Every (namespace, id) a hit carries, its own included.
    static func ids(of hit: ProgramHit) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for (k, v) in hit.ids where IDSpace.byKey[k] != nil && !IDSpace.notIdentifying.contains(k) {
            for one in IDSpace.split(v) { out[k, default: []].insert(IDSpace.normalise(k, one)) }
        }
        let own = ownSpace(hit.source)
        if IDSpace.byKey[own] != nil, !hit.sourceId.isEmpty { out[own, default: []].insert(IDSpace.normalise(own, hit.sourceId)) }
        return out
    }

    static func ownSpace(_ source: String) -> String { source }

    /// The namespace's source when it's one of ours (the owner of a "gog-slug" is "gog").
    static func owner(_ space: String) -> String {
        switch space {
        case "igdb-slug": return "igdb"
        case "gog-slug": return "gog"
        case "mobygames-slug": return "mobygames"
        default: return space
        }
    }

    /// Whether two clusters hold different entries from one source: two LaunchBox games, two Wikidata items — an
    /// original and its remaster. (Ids one source claims for another can be wrong, so only a source's own entries
    /// count.) Sources that list a program once per platform may join entries for different platforms; the Internet
    /// Archive has many items per program.
    static func conflict(_ a: Cluster, _ b: Cluster) -> String? {
        let sa = Set(a.hits.map(\.source)), sb = Set(b.hits.map(\.source))
        for src in sa.intersection(sb) {
            let pol = SourcePolicy.of(src)
            if pol.many { continue }
            func own(_ c: Cluster) -> Set<String> {
                Set(c.hits.filter { $0.source == src }.flatMap { [$0.sourceId] + IDSpace.split($0.ids[src]) })
            }
            guard own(a).isDisjoint(with: own(b)) else { continue }
            if pol.perPlatform {
                let fa = Set(a.hits.filter { $0.source == src }.flatMap(\.platforms).map(Platforms.family))
                let fb = Set(b.hits.filter { $0.source == src }.flatMap(\.platforms).map(Platforms.family))
                if !fa.isEmpty, !fb.isEmpty, fa.isDisjoint(with: fb) { continue }
            }
            return src
        }
        return nil
    }

    static func name(_ source: String) -> String {
        sourceNames[source] ?? IDSpace.byKey[source]?.name ?? source
    }

    nonisolated(unsafe) static var sourceNames: [String: String] = [:]

    /// Merges hits into programs (unranked).
    public static func merge(_ hits: [ProgramHit]) -> [ProgramResult] {
        // earlier releases first, so a source's original entry joins the program before its re-release does
        let hits = hits.enumerated().sorted { ($0.element.year ?? 9999, $0.offset) < ($1.element.year ?? 9999, $1.offset) }.map(\.element)
        var clusters: [Cluster] = hits.map(Cluster.init)
        var alive = Array(repeating: true, count: clusters.count)

        func join(_ i: Int, into j: Int, reason: String) {
            clusters[j].absorb(clusters[i], reason: reason)
            alive[i] = false
        }

        // 1. shared ids, the hubs' first (a Wikidata item, a Wikipedia page), so a chain of other sources' claims
        //    can't pull a remaster in before the hub has gathered the original's entries
        let spaces = ["wikidata", "wikipedia"] + IDSpace.all.map(\.key).filter { $0 != "wikidata" && $0 != "wikipedia" }
        var changed = true
        while changed {
            changed = false
            for space in spaces {
                var index: [String: Int] = [:]
                for i in clusters.indices where alive[i] {
                    for v in clusters[i].ids[space] ?? [] {
                        if let j = index[v], j != i, alive[j] {
                            if conflict(clusters[i], clusters[j]) != nil || remakeMismatch(clusters[i], clusters[j]) { continue }
                            join(i, into: j, reason: idReason(clusters[i], clusters[j], space: space, value: v))
                            changed = true
                            break
                        }
                        index[v] = i
                    }
                }
            }
        }

        // 2. loose matches
        changed = true
        while changed {
            changed = false
            outer: for i in clusters.indices where alive[i] {
                for j in clusters.indices where j < i && alive[j] {
                    if let why = looseMatch(clusters[i], clusters[j]) {
                        join(i, into: j, reason: why)
                        changed = true
                        break outer
                    }
                }
            }
        }

        return clusters.indices.filter { alive[$0] }.map { result(clusters[$0]) }
    }

    static func describe(_ c: Cluster) -> String {
        let first = c.hits.min { SourcePolicy.of($0.source).priority < SourcePolicy.of($1.source).priority } ?? c.hits[0]
        let sources = Array(Set(c.hits.map { name($0.source) })).sorted().joined(separator: ", ")
        return "“\(first.title)”\(first.year.map { " \($0)" } ?? "") (\(sources))"
    }

    static func idReason(_ moved: Cluster, _ into: Cluster, space: String, value: String) -> String {
        if space == "wikidata" { return "\(describe(moved)) — same Wikidata item (\(value))" }
        let label = IDSpace.byKey[space]?.name ?? space
        return "\(describe(moved)) — same \(label) ID (\(value))"
    }

    /// A remaster and its original never join, whatever ids sources claim for them.
    static func remakeMismatch(_ a: Cluster, _ b: Cluster) -> Bool {
        func remake(_ c: Cluster) -> Bool { c.hits.contains { !Set(Titles.tokens($0.title, keepStopwords: true)).isDisjoint(with: remakeWords) || $0.kind == "remake" } }
        return remake(a) != remake(b)
    }

    static func looseMatch(_ a: Cluster, _ b: Cluster) -> String? {
        guard !a.variants.isDisjoint(with: b.variants) else { return nil }
        if conflict(a, b) != nil || remakeMismatch(a, b) { return nil }
        // a store entry has no original date: "Myst" on Steam may be the 2021 remake. Only ids join those.
        let storeOnly = { (c: Cluster) in c.years.isEmpty && c.hits.allSatisfy { ["steam", "steamgriddb"].contains($0.source) } }
        if storeOnly(a) && !b.years.isEmpty || storeOnly(b) && !a.years.isEmpty { return nil }
        let exact = !a.normalised.isDisjoint(with: b.normalised)
        let sameBase = exact || !a.bases.isDisjoint(with: b.bases)
        let devAgree = a.developers.contains { x in b.developers.contains { Companies.agree(x, $0) } }
        if !a.developers.isEmpty, !b.developers.isEmpty, !devAgree { return nil }
        let yearOK: Bool
        if a.years.isEmpty || b.years.isEmpty {
            // without a year to check, only the same title will do (an archive item's year is often its upload's);
            // a version or platform suffix may differ, an edition ("Deluxe") may not
            yearOK = exact || !a.cores.isDisjoint(with: b.cores)
        } else {
            let tol = exact && devAgree ? 3 : 1
            yearOK = a.years.contains { x in b.years.contains { abs(x - $0) <= tol } }
        }
        guard yearOK else { return nil }
        let ap = a.families, bp = b.families
        if !ap.isEmpty, !bp.isEmpty, ap.isDisjoint(with: bp), !sameBase { return nil }
        var parts = ["title"]
        if !a.years.isEmpty && !b.years.isEmpty { parts.append("year") }
        if devAgree { parts.append("developer") }
        if !ap.isEmpty && !bp.isEmpty && !ap.isDisjoint(with: bp) { parts.append("platform") }
        let what = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "\(describe(a)) — \(what) match"
    }

    // MARK: Building results

    static func result(_ c: Cluster) -> ProgramResult {
        let hits = c.hits.sorted { SourcePolicy.of($0.source).priority < SourcePolicy.of($1.source).priority }
        let lead = hits[0]
        let strongYears = hits.filter { !SourcePolicy.of($0.source).weakYear }.compactMap(\.year)
        let year = mostCommonEarliest(strongYears) ?? hits.compactMap(\.year).min()
        var platforms: [String] = []
        for h in hits { for p in h.platforms where !platforms.contains(p) { platforms.append(p) } }
        platforms = Platforms.normalise(platforms)
        var ids: [String: String] = [:]
        var all: [String: [String]] = [:]
        for h in hits {
            var mine = h.ids
            if IDSpace.byKey[h.source] != nil {
                mine[h.source] = IDSpace.split(mine[h.source]).contains(h.sourceId)
                    ? mine[h.source] : ([h.sourceId] + IDSpace.split(mine[h.source])).joined(separator: ",")
            }
            for (k, v) in mine { for one in IDSpace.split(v).map({ IDSpace.normalise(k, $0) }) where !(all[k] ?? []).contains(one) { all[k, default: []].append(one) } }
        }
        for (k, v) in all { ids[k] = v.joined(separator: ",") }
        var links: [String: String] = [:]
        for (k, v) in all { if let first = v.first, let l = IDSpace.link(k, first), links[IDSpace.byKey[k].map { owner($0.key) } ?? k] == nil { links[owner(k)] = l } }
        for h in hits.reversed() { if let u = h.url { links[h.source] = u } }
        let thumb = thumbPriority.lazy.compactMap { s in hits.first { $0.source == s && $0.thumb != nil }?.thumb }.first ?? hits.compactMap(\.thumb).first
        let key = ids["wikidata"].map { "wikidata:\(IDSpace.split($0)[0])" } ?? "\(lead.source):\(lead.sourceId)"
        return ProgramResult(key: key, title: lead.title, year: year, platforms: platforms, developer: hits.compactMap(\.developer).first,
                             publisher: hits.compactMap(\.publisher).first, kind: kind(hits), thumb: thumb, ids: ids, links: links,
                             hits: hits, mergeReasons: c.reasons, score: 0)
    }

    static let thumbPriority = ["launchbox", "igdb", "steamgriddb", "screenscraper", "pcgamingwiki", "lutris", "gog", "wikipedia", "wikidata", "steam", "myabandonware"]

    static func mostCommonEarliest(_ ys: [Int]) -> Int? {
        let counts = Dictionary(ys.map { ($0, 1) }, uniquingKeysWith: +)
        // the earliest unless most sources agree on another (a re-release date is usually the outlier, not the first)
        guard let earliest = ys.min(), let top = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else { return nil }
        return top.value >= 2 && top.value > (counts[earliest] ?? 0) + 1 ? top.key : earliest
    }

    static func kind(_ hits: [ProgramHit]) -> String? {
        let kinds = hits.compactMap(\.kind)
        for k in ["demo", "remake", "expansion", "compilation"] where kinds.contains(k) {
            // a strong source has to say so, or most do
            let says = hits.filter { $0.kind == k }
            if says.contains(where: { ["wikidata", "igdb", "launchbox"].contains($0.source) }) || says.count * 2 > hits.count { return k }
        }
        return hits.first { $0.kind == "game" || $0.kind == "software" }?.kind
    }

    // MARK: Ranking and kinds

    /// Flags remakes and demos by title and by each other, then scores and sorts.
    public static func rank(_ results: [ProgramResult], query: String) -> [ProgramResult] {
        var rs = results
        for i in rs.indices { rs[i].kind = classify(rs[i], among: rs) }
        for i in rs.indices { rs[i].score = score(rs[i], query: query) }
        return rs.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.year ?? 9999) < ($1.year ?? 9999) }
    }

    static let remakeWords: Set<String> = ["remaster", "remastered", "remake", "hd", "reimagined", "anniversary", "definitive", "redux"]
    static let demoWords: Set<String> = ["demo", "trial", "preview", "sampler", "shareware"]
    static let compilationWords: Set<String> = ["collection", "trilogy", "anthology", "compilation", "pack", "bundle", "quadrilogy", "saga"]

    public static func classify(_ r: ProgramResult, among all: [ProgramResult]) -> String? {
        let toks = Set(Titles.tokens(r.title, keepStopwords: true))
        if !toks.isDisjoint(with: demoWords.subtracting(["shareware"])) { return "demo" }
        if r.kind == "remake" || !toks.isDisjoint(with: remakeWords) { return "remake" }
        if r.kind == "demo" || r.kind == "expansion" { return r.kind }
        if r.kind == "compilation" || toks.count > 1 && !toks.isDisjoint(with: compilationWords) { return "compilation" }
        // a much later program whose title is an older one's ("Zoombinis" 2015 after "Logical Journey of the Zoombinis")
        if let y = r.year, y >= 2008 {
            let mine = Set(Titles.tokens(Titles.base(r.title)))
            for o in all where o.key != r.key {
                guard let oy = o.year, oy <= 2005, y - oy >= 8, o.kind != "demo" else { continue }
                if !mine.isEmpty, mine.isSubset(of: Set(Titles.tokens(o.title))) { return "remake" }
            }
        }
        return r.kind
    }

    public static func score(_ r: ProgramResult, query: String) -> Double {
        let titles = r.hits.map(\.title) + [r.title]
        let alts = r.hits.flatMap(\.alternateTitles)
        let sim = max(titles.map { Titles.similarity(query, $0) }.max() ?? 0, (alts.map { Titles.similarity(query, $0) }.max() ?? 0) * 0.9)
        var s = 46 * sim + (sim >= 0.95 ? 8 : 0)
        if let y = r.year {
            if (1980...2010).contains(y) { s += 12 } else if y < 1980 { s += 6 } else if (2011...2014).contains(y) { s += 4 } else if y >= 2015 { s -= 4 }
        }
        if r.platforms.contains(where: Platforms.isOldDesktop) { s += 8 } else if r.platforms.isEmpty { s += 2 }
        let sources = Set(r.hits.map(\.source)).count
        s += min(16, 16 * log2(1 + Double(sources)) / log2(9))
        let mediaSources = Set(r.hits.map(\.source)).filter { SourcePolicy.of($0).media }.count
        s += min(6, Double(mediaSources) * 1.5)
        if r.thumb != nil { s += 3 }
        switch r.kind {
        case "demo": s -= 12
        case "remake": s -= 6
        case "compilation", "expansion": s -= 5
        default: break
        }
        return (min(100, max(0, s)) * 10).rounded() / 10
    }
}
