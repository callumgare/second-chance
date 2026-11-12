import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Catalog")

/// What the person said about merging search results, kept in `merges.json` in the data folder and applied to
/// every search after the automatic merge: hits they separated stay apart from the automatic merge, and hits they
/// merged are one program whatever it thought. A hit is named by its key, `<source>:<id>`, so a merge made in one
/// search holds in the next. Second Chance's own programs are hits too (source `secondchance`, id the bundle id).
nonisolated public struct MergeRules: Codable, Sendable, Equatable {
    /// Sets of hits that are one program.
    public var groups: [[String]] = []
    /// Hits kept out of the automatic merge (each stands alone unless a group names it).
    public var apart: [String] = []

    public init() {}

    public static func key(_ h: ProgramHit) -> String { "\(h.source):\(h.sourceId)" }

    /// Makes these hits one program: one group with every hit named, joined with any group already holding one.
    public mutating func merge(_ keys: [String]) {
        var joined = Set(keys)
        groups.removeAll { g in
            guard !joined.isDisjoint(with: g) else { return false }
            joined.formUnion(g)
            return true
        }
        if joined.count > 1 { groups.append(joined.sorted()) }
    }

    /// Takes one hit out of its program: out of any group, and out of the automatic merge.
    public mutating func separate(_ key: String) {
        for i in groups.indices { groups[i].removeAll { $0 == key } }
        groups.removeAll { $0.count < 2 }
        if !apart.contains(key) { apart.append(key) }
    }

    /// Undoes the merges that hold any of these hits, and lets them merge automatically again.
    public mutating func unmerge(_ keys: [String]) {
        let set = Set(keys)
        groups.removeAll { !set.isDisjoint(with: $0) }
        apart.removeAll { set.contains($0) }
    }

    /// The results for these hits with the rules applied: the automatic merge of every hit not kept apart, each
    /// kept-apart hit on its own, then each group's results made one (`mergedByYou`).
    public func apply(_ hits: [ProgramHit]) -> [ProgramResult] {
        let apartSet = Set(apart)
        var results = Merger.merge(hits.filter { !apartSet.contains(Self.key($0)) })
            + hits.filter { apartSet.contains(Self.key($0)) }.flatMap { Merger.merge([$0]) }
        for g in groups {
            let keys = Set(g)
            let holding = results.indices.filter { i in results[i].hits.contains { keys.contains(Self.key($0)) } }
            guard holding.count > 1 else { continue }
            let combined = Merger.combine(holding.map { results[$0] })
            for i in holding.reversed() { results.remove(at: i) }
            results.append(combined)
        }
        return results
    }
}

nonisolated extension Merger {
    /// Results the person merged, as one: every hit, the reasons each had, and theirs.
    static func combine(_ results: [ProgramResult]) -> ProgramResult {
        let hits = results.flatMap(\.hits)
        var c = Cluster(hits[0])
        for h in hits.dropFirst() { c.absorb(Cluster(h), reason: "") }
        c.reasons = results.flatMap(\.mergeReasons) + ["merged by you: " + results.map { r in
            "“\(r.title)”\(r.year.map { " \($0)" } ?? "")"
        }.joined(separator: ", ")]
        var r = result(c)
        r.mergedByYou = true
        return r
    }
}

extension Catalog {
    var mergesFile: URL { lab.store.root.appendingPathComponent("merges.json") }

    /// The person's merges (none until they make one).
    public func mergeRules() -> MergeRules {
        if let rules = loadedRules { return rules }
        var rules = MergeRules()
        if let d = try? Data(contentsOf: mergesFile) {
            do { rules = try JSONDecoder().decode(MergeRules.self, from: d) } catch { logger.warning("Couldn't read merges.json: \(error)") }
        }
        loadedRules = rules
        return rules
    }

    public nonisolated enum MergeChange: Sendable {
        case merge([String]), separate(String), unmerge([String])
    }

    /// Changes the merges, keeps them, and sends every search again with them applied. Results merged that had each
    /// been opened as a program make one program of them; a result split leaves its program with the part that has
    /// the most sources (OpenedPrograms).
    public func changeMerges(_ change: MergeChange) async throws -> MergeRules {
        var rules = mergeRules()
        var split: [(slug: String, hits: Set<String>)] = []
        switch change {
        case .merge(let keys): await mergePrograms(keys)
        case .separate(let key): split = await programsBeforeSplit([key])
        case .unmerge(let keys): split = await programsBeforeSplit(keys)
        }
        switch change {
        case .merge(let keys): rules.merge(keys)
        case .separate(let key): rules.separate(key)
        case .unmerge(let keys): rules.unmerge(keys)
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rules).write(to: mergesFile, options: .atomic)
        loadedRules = rules
        for id in searchOrder { recompute(id) }
        await settleSplit(split)
        for id in searchOrder { await emit(id, force: true) }
        return rules
    }

    // MARK: Second Chance's programs

    static let hostSource = "secondchance"

    /// The host's programs as search hits, those whose titles share a word with the query, so the automatic merge
    /// can match each with the catalogues' entries (by the ids its program already has, else title, year and maker).
    func hostHits(_ q: String) async -> [ProgramHit] {
        var out: [ProgramHit] = []
        for k in lab.host.knownPrograms where Titles.similarity(q, k.title) > 0 || k.id.localizedCaseInsensitiveContains(q) {
            var h = ProgramHit(source: Self.hostSource, sourceId: k.id, title: k.title)
            h.year = k.year
            h.platforms = Platforms.normalise(k.platforms)
            h.developer = k.developer
            h.publisher = k.publisher
            if let p = await lab.store.program(KnownProgram.slug(forBundle: k.id)), let ids = p.ids { h.ids = ids }
            out.append(h)
        }
        return out
    }

    /// Finds the host's program in the catalogues (a search for its title), and keeps the ids of the result it
    /// merged into in its program, so gathering looks it up by them. Returns whether it was found.
    @discardableResult
    public func matchKnown(_ slug: String, bundle: String) async -> Bool {
        guard let k = lab.host.knownPrograms.first(where: { $0.id == bundle }) else { return false }
        let id = await search(k.title)
        let deadline = Date().addingTimeInterval(120)
        while searches[id]?.snapshot.done != true, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let r = searches[id]?.snapshot.results.first(where: { $0.hits.contains { $0.source == Self.hostSource && $0.sourceId == bundle } }),
              r.hits.count > 1, var p = await lab.store.program(slug) else { return false }
        p.ids = (p.ids ?? [:]).merging(r.ids) { a, _ in a }
        if p.platforms?.isEmpty ?? true { p.platforms = r.platforms }
        do { try await lab.store.saveProgram(p) } catch {
            logger.warning("Couldn't keep \(slug)'s catalogue ids: \(error)")
            return false
        }
        return true
    }

    /// A host's program opened for the first time: found in the catalogues (a job), then gathered from them.
    public func matchThenGather(_ slug: String, bundle: String) async {
        let title = lab.host.knownPrograms.first { $0.id == bundle }?.title ?? slug
        await lab.jobs.enqueue(title: "Find \(title) in the catalogues", program: slug, group: "match") { [self] progress in
            await progress(0.1, "Searching")
            let found = await self.matchKnown(slug, bundle: bundle)
            await progress(0.9, found ? "Found: gathering with its ids" : "Not matched: gathering by its title")
            _ = try await self.gather(slug)
        }
    }
}
