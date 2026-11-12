import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Search")

/// Stage 1's search: fans a query out to every ready source at once, merges and ranks the hits as they arrive, asks
/// Wikidata for the items behind the ids the other sources gave (the merge hub), and streams snapshots to the page.
/// Stage 2's gathering lives in Gather.swift.
public actor Catalog {
    public let lab: Lab
    public let ctx: SourceContext
    public nonisolated let programSources: [any ProgramSource]
    public nonisolated let mediaSources: [any MediaSource]
    let wikidata: WikidataSource
    let screenScraper: ScreenScraperSource
    var searches: [String: SearchState] = [:]
    var searchOrder: [String] = []
    var loadedRules: MergeRules?

    public struct SourceProgress: Codable, Sendable {
        public var id: String
        public var name: String
        public var state: SourceState
        public var note: String?
        public var running: Bool
        public var count: Int
    }

    public struct Snapshot: Codable, Sendable {
        public var type = "search"
        public var id: String
        public var q: String
        public var sources: [SourceProgress]
        public var results: [ProgramResult]
        public var done: Bool
    }

    struct SearchState {
        var snapshot: Snapshot
        var hits: [ProgramHit] = []
        var lastEmit = Date.distantPast
        var emitPending = false
    }

    /// The one the server made (for code outside the catalog that needs `downloadURL`).
    nonisolated(unsafe) public static var shared: Catalog?

    public init(lab: Lab) {
        self.lab = lab
        let ctx = SourceContext(http: HTTP(cacheDir: lab.store.root.appendingPathComponent("cache/http")), env: lab.env,
                                dataDir: lab.store.root, jobs: lab.jobs)
        self.ctx = ctx
        let wd = WikidataSource(ctx), wp = WikipediaSource(ctx), lb = LaunchBoxSource(ctx), tgdb = TheGamesDBSource(ctx)
        let igdb = IGDBSource(ctx), sgdb = SteamGridDBSource(ctx), ss = ScreenScraperSource(ctx), pcgw = PCGamingWikiSource(ctx)
        let lutris = LutrisSource(ctx), steam = SteamSource(ctx), gog = GOGSource(ctx), ia = InternetArchiveSource(ctx)
        let mya = MyAbandonwareSource(ctx), ww = WinWorldSource(ctx)
        wikidata = wd
        screenScraper = ss
        programSources = [wd, wp, lb, tgdb, igdb, sgdb, ss, pcgw, lutris, steam, gog, ia, mya, ww]
        mediaSources = [lb, wd, wp, CommonsSource(ctx), ia, sgdb, igdb, ss, pcgw, tgdb, lutris, steam, gog, mya, ww,
                        MacintoshRepositorySource(ctx), OpenverseSource(ctx), BraveSource(ctx)]
        Catalog.shared = self
    }

    /// A program's summary, as `GET /api/programs` lists it.
    public func summary(_ slug: String) async -> Lab.ProgramSummary? {
        await lab.programs().first { $0.slug == slug }
    }

    /// Starts (or refreshes) the local copies that are missing or more than a week old, as jobs.
    public func refreshLocalCopies(force: Bool = false) async {
        for s in programSources { if let l = s as? any LocalCopySource { await l.refreshIfNeeded(force: force) } }
    }

    /// Every source, program and media alike, and the link-only ones.
    public func sources() async -> [SourceInfo] {
        var out: [SourceInfo] = [], seen = Set<String>()
        let mediaIds = Set(await withTaskGroup(of: String.self) { g in
            for s in mediaSources { g.addTask { await s.info.id } }
            var ids: [String] = []
            for await id in g { ids.append(id) }
            return ids
        })
        let searchIds = Set(await withTaskGroup(of: String.self) { g in
            for s in programSources { g.addTask { await s.info.id } }
            var ids: [String] = []
            for await id in g { ids.append(id) }
            return ids
        })
        for s in programSources { var i = await s.info; i.search = true; i.media = mediaIds.contains(i.id); if seen.insert(i.id).inserted { out.append(i) } }
        for s in mediaSources { var i = await s.info; i.media = true; i.search = searchIds.contains(i.id); if seen.insert(i.id).inserted { out.append(i) } }
        for l in LinkOnlySource.all where seen.insert(l.info.id).inserted { out.append(l.info) }
        return out
    }

    func names() async -> [String: String] {
        var n: [String: String] = [:]
        for i in await sources() { n[i.id] = i.name }
        return n
    }

    // MARK: Searching

    public func search(_ q: String) async -> String {
        let id = UUID().uuidString.lowercased()
        var sources: [SourceProgress] = []
        var ready: [(Int, any ProgramSource)] = []
        for s in programSources {
            let i = await s.info
            if i.state == .ready { ready.append((sources.count, s)) }
            sources.append(SourceProgress(id: i.id, name: i.name, state: i.state, note: i.note, running: i.state == .ready, count: 0))
        }
        let mr = await MacintoshRepositorySource(ctx).info
        sources.append(.init(id: mr.id, name: mr.name, state: mr.state, note: mr.note, running: false, count: 0))
        for l in LinkOnlySource.all { sources.append(.init(id: l.info.id, name: l.info.name, state: .linkOnly, note: l.info.note, running: false, count: 0)) }
        // the host's own programs take part, so they merge with the catalogues' entries
        let own = await hostHits(q)
        if !lab.host.knownPrograms.isEmpty {
            sources.insert(.init(id: Self.hostSource, name: "Second Chance", state: .ready, note: "its own programs", running: false, count: own.count), at: 0)
        }
        Merger.sourceNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.name) })
        var state = SearchState(snapshot: Snapshot(id: id, q: q, sources: sources, results: [], done: false))
        state.hits = own
        searches[id] = state
        searchOrder.append(id)
        if searchOrder.count > 30 { searches[searchOrder.removeFirst()] = nil }
        let shift = lab.host.knownPrograms.isEmpty ? 0 : 1
        Task { await self.run(id, q, ready.map { ($0.0 + shift, $0.1) }) }
        return id
    }

    public func snapshot(_ id: String) async -> Snapshot? {
        guard let s = searches[id]?.snapshot else { return nil }
        return await linked(s)
    }

    func run(_ id: String, _ q: String, _ ready: [(Int, any ProgramSource)]) async {
        recompute(id)
        await emit(id, force: true)
        await withTaskGroup(of: (Int, Result<[ProgramHit], Error>).self) { group in
            for (i, s) in ready {
                group.addTask {
                    do { return (i, .success(try await withTimeout(60) { try await s.search(q) })) } catch { return (i, .failure(error)) }
                }
            }
            for await (i, r) in group {
                guard var st = searches[id] else { continue }
                switch r {
                case .success(let hits):
                    st.hits += hits
                    st.snapshot.sources[i].count = hits.count
                case .failure(let e):
                    st.snapshot.sources[i].note = "failed: \(e)"
                }
                // Wikidata keeps going: it still has to look up the other sources' ids
                st.snapshot.sources[i].running = st.snapshot.sources[i].id == "wikidata"
                searches[id] = st
                recompute(id)
                await emit(id)
            }
        }
        // the hub: Wikidata items for ids the other sources gave
        if let wi = searches[id]?.snapshot.sources.firstIndex(where: { $0.id == "wikidata" }), searches[id]?.snapshot.sources[wi].state == .ready {
            let hits = searches[id]?.hits ?? []
            let known = Set(hits.filter { $0.source == "wikidata" }.map(\.sourceId))
            do {
                let extra = try await withTimeout(60) { try await self.wikidata.enrich(hits, known: known) }
                searches[id]?.hits += extra
                searches[id]?.snapshot.sources[wi].count += extra.count
            } catch {
                searches[id]?.snapshot.sources[wi].note = "linking ids failed: \(error)"
            }
            searches[id]?.snapshot.sources[wi].running = false
        }
        searches[id]?.snapshot.done = true
        recompute(id)
        await emit(id, force: true)
    }

    func recompute(_ id: String) {
        guard var st = searches[id] else { return }
        st.snapshot.results = Self.results(st.hits, query: st.snapshot.q, rules: mergeRules())
        // the id-only and link-only sources count the results that link to them
        for i in st.snapshot.sources.indices where ["macintoshrepository", "mobygames", "macintoshgarden", "gamefaqs", "discmaster"].contains(st.snapshot.sources[i].id) {
            let sid = st.snapshot.sources[i].id
            st.snapshot.sources[i].count = st.snapshot.results.filter { $0.ids[sid] != nil || (sid == "mobygames" && $0.ids["mobygames-slug"] != nil) }.count
        }
        searches[id] = st
    }

    /// Merged, ranked results for a query's hits (the pure part, for tests too).
    public static func results(_ hits: [ProgramHit], query: String, limit: Int = 40, rules: MergeRules = MergeRules()) -> [ProgramResult] {
        var merged = rules.apply(Merger.collapse(hits))
        for i in merged.indices {
            for (k, v) in LinkOnlySource.searchLinks(title: merged[i].title, platforms: merged[i].platforms, ids: merged[i].ids) where merged[i].links[k] == nil {
                merged[i].links[k] = v
            }
        }
        let ranked = Merger.rank(merged, query: query)
        // drop what shares no word with the query (a full-text search's neighbours: "Riven" for "myst")
        let relevant = ranked.filter { r in
            (r.hits.map(\.title) + r.hits.flatMap(\.alternateTitles)).contains { Titles.similarity(query, $0) > 0 }
        }
        return Array(relevant.prefix(limit))
    }

    func emit(_ id: String, force: Bool = false) async {
        guard var st = searches[id] else { return }
        let since = Date().timeIntervalSince(st.lastEmit)
        if !force && since < 0.3 {
            if !st.emitPending {
                st.emitPending = true
                searches[id] = st
                Task {
                    try? await Task.sleep(nanoseconds: UInt64((0.3 - since) * 1e9))
                    await self.flush(id)
                }
            }
            return
        }
        st.lastEmit = Date()
        st.emitPending = false
        searches[id] = st
        await send(st.snapshot)
    }

    func flush(_ id: String) async {
        guard var st = searches[id], st.emitPending else { return }
        st.emitPending = false
        st.lastEmit = Date()
        searches[id] = st
        await send(st.snapshot)
    }

    func send(_ s: Snapshot) async {
        let s = await linked(s)
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? e.encode(s), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        await lab.jobs.broadcast(obj)
    }

    // MARK: Programs

    /// Creates a program from a chosen result: a slug from its title (with the year if that's taken), and
    /// `program.json` with its title, year, ids and platforms.
    public func createProgram(_ r: ProgramResult) async throws -> String {
        // opened before (it shares ids with a program, or it was merged with one): that program again
        if r.bundleId == nil, let slug = await openedProgram(for: r), var p = await lab.store.program(slug) {
            p.ids = (p.ids ?? [:]).merging(r.ids) { a, _ in a }
            try await lab.store.saveProgram(p)
            return slug
        }
        if let bundle = r.bundleId {
            // what was opened from the result before (by its ids or title), to move into the bundle's program if it's
            // only now made: choosing Second Chance's program carries on the work done on it, rather than starting over
            let before = linking([r], await openedPrograms()).first?.programs ?? []
            let (slug, created) = try await lab.openKnown(bundle)
            if created {
                for o in before where o.slug != slug {
                    try await lab.store.absorb(o.slug, into: slug)
                    logger.notice("Moved program \(o.slug) into \(slug), the program of the bundle its result is")
                }
            }
            if var p = await lab.store.program(slug) {
                p.ids = (p.ids ?? [:]).merging(r.ids) { a, _ in a }
                if p.platforms?.isEmpty ?? true { p.platforms = r.platforms }
                try await lab.store.saveProgram(p)
            }
            return slug
        }
        let base = Store.slugify(r.title).isEmpty ? "program" : Store.slugify(r.title)
        var slug = base
        let existing = await lab.store.program(slug)
        if let existing {
            // the same program again: reuse it
            if existing.ids?["wikidata"] != nil && existing.ids?["wikidata"] == r.ids["wikidata"] || (existing.title == r.title && existing.year == r.year) {
                var p = existing
                p.ids = (p.ids ?? [:]).merging(r.ids) { a, _ in a }
                p.platforms = r.platforms
                try await lab.store.saveProgram(p)
                return slug
            }
            slug = r.year.map { "\(base)-\($0)" } ?? base
            var n = 2
            while await lab.store.program(slug) != nil { slug = "\(base)-\(r.year.map(String.init) ?? "")\(r.year == nil ? "" : "-")\(n)"; n += 1 }
        }
        var p = Store.ProgramInfo(slug: slug, title: r.title, year: r.year, ids: r.ids, platforms: r.platforms, updated: nil)
        p.developer = r.developer
        p.publisher = r.publisher
        try await lab.store.saveProgram(p)
        return slug
    }

    public func identity(_ slug: String) async -> ProgramIdentity? {
        guard let p = await lab.store.program(slug) else { return nil }
        var id = ProgramIdentity(title: p.title, year: p.year)
        id.platforms = p.platforms ?? []
        id.ids = p.ids ?? [:]
        id.developer = p.developer
        id.publisher = p.publisher
        return id
    }

    /// The URL to download a remote picture from (ScreenScraper's need the credentials put back).
    public func downloadURL(_ m: RemoteMedia) async -> URL? {
        guard let u = URL(string: m.url) else { return nil }
        return m.source == "screenscraper" ? await screenScraper.authorise(u) : u
    }
}

nonisolated extension Merger {
    /// Folds a source's duplicate entries (TheGamesDB lists Myst for PC twice) into one hit carrying both ids.
    public static func collapse(_ hits: [ProgramHit]) -> [ProgramHit] {
        var out: [ProgramHit] = []
        var index: [String: Int] = [:]
        for h in hits {
            guard SourcePolicy.of(h.source).perPlatform else { out.append(h); continue }
            let key = [h.source, Titles.normalise(h.title), Set(h.platforms.map(Platforms.family)).sorted().joined(separator: "+"),
                       h.year.map(String.init) ?? "?"].joined(separator: "|")
            if let i = index[key] {
                let ids = IDSpace.split(out[i].ids[h.source]) + [out[i].sourceId, h.sourceId]
                var seen = Set<String>()
                out[i].ids[h.source] = ids.filter { seen.insert($0).inserted }.joined(separator: ",")
                out[i].alternateTitles = Array(Set(out[i].alternateTitles + h.alternateTitles))
                if out[i].thumb == nil { out[i].thumb = h.thumb }
                for (k, v) in h.ids where out[i].ids[k] == nil { out[i].ids[k] = v }
            } else {
                index[key] = out.count
                out.append(h)
            }
        }
        return out
    }
}

nonisolated struct TimeoutError: Error, CustomStringConvertible { var description: String { "timed out" } }

nonisolated func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await work() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); throw TimeoutError() }
        // the first to finish: the work, or the timeout throwing
        guard let r = try await g.next() else { throw TimeoutError() }
        g.cancelAll()
        return r
    }
}
