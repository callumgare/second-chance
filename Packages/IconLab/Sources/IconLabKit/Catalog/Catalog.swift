import Foundation

// Stage 1 and 2's sources: catalogues that know programs (search) and places that have pictures of them (media).
// One adapter per source, each conforming to `ProgramSource` and/or `MediaSource`. `Catalog` fans a search out to
// every source, merges hits that are the same program, ranks them, and streams progress as events.

/// Whether a source can be used right now.
nonisolated public enum SourceState: String, Codable, Sendable {
    case ready          // usable
    case needsKey       // needs a key or credentials it doesn't have (`note` says which .env keys)
    case linkOnly       // forbids automated access: we only link to it (Wikidata gives us its ids)
    case disabled
}

nonisolated public struct SourceInfo: Codable, Sendable {
    public var id: String           // "wikidata"
    public var name: String         // "Wikidata"
    public var state: SourceState
    public var note: String?        // "needs IGDB_CLIENT_ID and IGDB_CLIENT_SECRET in .env"
    public var local: Bool          // answers from a local copy (LaunchBox, TheGamesDB dumps)
    public var homepage: String?
    /// What it's used for: finding programs (stage 1), pictures (stage 2), or both.
    public var search: Bool?
    public var media: Bool?
    public init(id: String, name: String, state: SourceState, note: String? = nil, local: Bool = false, homepage: String? = nil) {
        self.id = id; self.name = name; self.state = state; self.note = note; self.local = local; self.homepage = homepage
    }
}

/// One source's idea of a program.
nonisolated public struct ProgramHit: Codable, Sendable, Hashable {
    public var source: String               // source id
    public var sourceId: String             // the program's id in that source
    public var title: String
    public var alternateTitles: [String] = []
    public var year: Int?
    public var platforms: [String] = []     // normalised: "Windows", "Windows 3.x", "DOS", "Mac OS", "Mac OS X", "Linux", …
    public var developer: String?
    public var publisher: String?
    public var kind: String?                // "game" | "software" | "demo" | "remake" | "compilation" | "expansion"
    public var thumb: String?               // a small picture URL (box front, icon, logo)
    public var url: String?                 // the program's page at the source
    public var ids: [String: String] = [:]  // other sources' ids it knows: ["wikidata": "Q…", "igdb": "…", "mobygames": "…", …]
    public var summary: String?
    public init(source: String, sourceId: String, title: String) { self.source = source; self.sourceId = sourceId; self.title = title }
}

/// Hits merged into one program, with why they were merged, ranked against the query.
nonisolated public struct ProgramResult: Codable, Sendable {
    public var key: String                  // stable id for the merged result (e.g. "wikidata:Q…" or the first hit's)
    public var title: String
    public var year: Int?
    public var platforms: [String]
    public var developer: String?
    public var publisher: String?
    public var kind: String?
    public var thumb: String?
    public var ids: [String: String]        // every id known, merged
    public var links: [String: String]      // source id → page URL (link-only sources included)
    public var hits: [ProgramHit]
    public var mergeReasons: [String]       // "same Wikidata item", "title + year + publisher match", …
    public var score: Double                // 0…100
    /// The person merged it (MergeRules): it can be unmerged.
    public var mergedByYou: Bool?
    /// One of its hits is the host's program with this bundle id: choosing it opens that program.
    public var bundleId: String?
}

/// What stage 2 knows about the chosen program, for media sources to look it up by.
nonisolated public struct ProgramIdentity: Codable, Sendable {
    public var title: String
    public var alternateTitles: [String] = []
    public var year: Int?
    public var platforms: [String] = []
    public var ids: [String: String] = [:]
    public var developer: String?
    public var publisher: String?
    public init(title: String, year: Int? = nil) { self.title = title; self.year = year }
}

/// A picture a source has of a program (not downloaded yet).
nonisolated public struct RemoteMedia: Codable, Sendable, Hashable {
    public var source: String               // source id
    public var url: String                  // the largest copy the source offers
    public var thumbUrl: String?            // a small copy, if the source has one
    public var kind: String?                // MediaKind (box-front, disc, logo, …) when the source labels it
    public var sourceLabel: String?         // the source's own label ("Box - Front", "Clear Logo")
    public var width: Int?
    public var height: Int?
    public var region: String?
    public var title: String?               // caption / file name
    public var pageUrl: String?             // where a person can see it at the source
    public var license: String?
    /// For pictures a general search found: how likely they're about the program (Relevance), from their words.
    public var relevance: Relevance.Score?
    public init(source: String, url: String) { self.source = source; self.url = url }
}

nonisolated public protocol ProgramSource: Sendable {
    var info: SourceInfo { get async }
    func search(_ query: String) async throws -> [ProgramHit]
}

nonisolated public protocol MediaSource: Sendable {
    var info: SourceInfo { get async }
    func media(for program: ProgramIdentity) async throws -> [RemoteMedia]
}

/// Keys and settings from the repo's `.env` (and the environment, which wins).
nonisolated public struct Env: Sendable {
    public let values: [String: String]

    public init(file: URL?) {
        var v: [String: String] = [:]
        if let file, let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
                var value = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                v[String(l[..<eq]).trimmingCharacters(in: .whitespaces)] = value
            }
        }
        for (k, val) in ProcessInfo.processInfo.environment { v[k] = val }
        values = v
    }

    public subscript(_ k: String) -> String? { values[k].flatMap { $0.isEmpty ? nil : $0 } }
}
