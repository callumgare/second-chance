import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Catalog")

/// A program already opened from a search result, as the result shows it: what it holds, so a result with
/// designs stands out from one never opened.
nonisolated public struct OpenedProgram: Codable, Sendable, Equatable {
    public var slug: String
    public var title: String
    public var media: Int
    public var picked: Int
    public var pins: Int
    /// The subject image's thumbnail, as the program list shows it.
    public var thumb: String?
    /// Second Chance's bundle, when it's the host's own program (which keeps the rest when they're combined).
    public var bundleId: String?
}

/// Search results and the programs opened from them: a program is a result's when they share ids (the catalogue
/// ids it was opened with, kept in `program.json`) or the host's bundle. Merging results that had each been opened
/// merges the programs; separating a result leaves the program with the side that has the most sources.
extension Catalog {
    struct Opened: Sendable {
        var info: Store.ProgramInfo
        var link: OpenedProgram
    }

    func openedPrograms() async -> [Opened] {
        var out: [Opened] = []
        for p in await lab.store.programs() {
            let media = await lab.store.media(p.slug)
            let subject = Treatments.defaultRoles(media)["subject"]
            out.append(Opened(info: p, link: OpenedProgram(
                slug: p.slug, title: p.title, media: media.count, picked: media.filter(\.picked).count,
                pins: await lab.store.state(p.slug).pins.count, thumb: subject.map { "/api/programs/\(p.slug)/media/\($0)/thumb" },
                bundleId: p.bundleId)))
        }
        return out
    }

    /// How strongly a program is this result: its bundle, then each id they share.
    static func overlap(_ p: Store.ProgramInfo, _ r: ProgramResult) -> Int {
        var n = 0
        if let b = p.bundleId, b == r.bundleId || r.hits.contains(where: { $0.source == hostSource && $0.sourceId == b }) { n += 100 }
        for (k, v) in p.ids ?? [:] where r.ids[k] == v { n += 1 }
        return n
    }

    /// Each program on the result it best matches, the one with the most designs (then pictures) first.
    func linking(_ results: [ProgramResult], _ opened: [Opened]) -> [ProgramResult] {
        var out = results.map { r -> ProgramResult in var r = r; r.programs = nil; return r }
        for o in opened {
            let scores = out.map { Self.overlap(o.info, $0) }
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { continue }
            out[best].programs = ((out[best].programs ?? []) + [o.link]).sorted { ($0.pins, $0.media) > ($1.pins, $1.media) }
        }
        return out
    }

    func linked(_ s: Snapshot) async -> Snapshot {
        var s = s
        s.results = linking(s.results, await openedPrograms())
        return s
    }

    /// The program a result was opened as before (the one with the most designs), so choosing it again opens that.
    func openedProgram(for r: ProgramResult) async -> String? {
        linking([r], await openedPrograms()).first?.programs?.first?.slug
    }

    // MARK: Merging and separating

    /// The results in any search now that hold one of these hits.
    func resultsHolding(_ keys: Set<String>) -> [ProgramResult] {
        var seen = Set<String>(), out: [ProgramResult] = []
        for id in searchOrder {
            for r in searches[id]?.snapshot.results ?? [] where r.hits.contains(where: { keys.contains(MergeRules.key($0)) }) {
                if seen.insert(r.key).inserted { out.append(r) }
            }
        }
        return out
    }

    /// Of several results, the one that keeps a program: the host's program's, else the one with most sources.
    static func keeper(_ rs: [ProgramResult]) -> ProgramResult? {
        rs.max { a, b in
            let ha = a.bundleId != nil, hb = b.bundleId != nil
            return ha != hb ? !ha : a.hits.count < b.hits.count
        }
    }

    /// Results the person merged: the programs opened from them become one. The host's program takes the rest,
    /// else the one whose result had the most sources (then the most designs and pictures).
    func mergePrograms(_ keys: [String]) async {
        let before = resultsHolding(Set(keys))
        let opened = await openedPrograms()
        var owners: [(Opened, ProgramResult)] = []
        for o in opened {
            let scores = before.map { Self.overlap(o.info, $0) }
            if let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 { owners.append((o, before[best])) }
        }
        guard owners.count > 1, let target = owners.max(by: { a, b in
            let ha = a.0.info.bundleId != nil, hb = b.0.info.bundleId != nil
            if ha != hb { return !ha }
            if a.1.hits.count != b.1.hits.count { return a.1.hits.count < b.1.hits.count }
            return (a.0.link.pins, a.0.link.media) < (b.0.link.pins, b.0.link.media)
        })?.0 else { return }
        do {
            for (o, _) in owners where o.info.slug != target.info.slug {
                try await lab.store.absorb(o.info.slug, into: target.info.slug)
                logger.notice("Merged program \(o.info.slug) into \(target.info.slug)")
            }
            guard var p = await lab.store.program(target.info.slug) else { return }
            for (o, r) in owners {
                p.ids = (p.ids ?? [:]).merging(o.info.ids ?? [:]) { a, _ in a }.merging(r.ids) { a, _ in a }
            }
            try await lab.store.saveProgram(p)
        } catch {
            logger.error("Couldn't merge the programs into \(target.info.slug): \(error)")
        }
    }

    /// Before a result is split: which program each result holding these hits is, to settle after.
    func programsBeforeSplit(_ keys: [String]) async -> [(slug: String, hits: Set<String>)] {
        let before = resultsHolding(Set(keys))
        let opened = await openedPrograms()
        return before.compactMap { r in
            linking([r], opened).first?.programs?.first.map { ($0.slug, Set(r.hits.map(MergeRules.key))) }
        }
    }

    /// After a split: each program stays with the part of its old result with the most sources (the host's
    /// program's, if it's one), and forgets the ids only the other parts have, so they no longer open it.
    func settleSplit(_ split: [(slug: String, hits: Set<String>)]) async {
        for (slug, hits) in split {
            let parts = resultsHolding(hits)
            guard parts.count > 1, let keep = Self.keeper(parts), var p = await lab.store.program(slug) else { continue }
            var ids = p.ids ?? [:]
            for part in parts where part.key != keep.key {
                for (k, v) in part.ids where ids[k] == v && keep.ids[k] != v { ids[k] = nil }
            }
            guard ids != (p.ids ?? [:]) else { continue }
            p.ids = ids
            do { try await lab.store.saveProgram(p) } catch { logger.error("Couldn't update \(slug)'s ids after a split: \(error)") }
        }
    }
}
