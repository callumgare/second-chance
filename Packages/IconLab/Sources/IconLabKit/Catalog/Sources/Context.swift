import Foundation

/// What a source needs: the shared HTTP client, keys, where it may keep files, and the job queue (for downloads of
/// local copies).
nonisolated public struct SourceContext: Sendable {
    public let http: HTTP
    public let env: Env
    public let dataDir: URL
    public let jobs: Jobs

    public init(http: HTTP, env: Env, dataDir: URL, jobs: Jobs) {
        self.http = http; self.env = env; self.dataDir = dataDir; self.jobs = jobs
    }

    public var sourcesDir: URL { dataDir.appendingPathComponent("sources") }

    /// The keys that are missing from `.env`, if any.
    func missing(_ keys: [String]) -> [String] { keys.filter { env[$0] == nil } }

    func needsKeyNote(_ keys: [String]) -> String {
        "needs \(keys.joined(separator: " and ")) in .env"
    }
}

/// A source with a local copy it refreshes (weekly) in a job.
nonisolated public protocol LocalCopySource: Sendable {
    func refreshIfNeeded(force: Bool) async
}

/// A source whose media URLs need credentials added at download time (they're stored without them).
nonisolated public protocol AuthorisingSource: Sendable {
    func authorise(_ url: URL) async -> URL
}

/// Pictures a source has, for sources that also answer searches with ids they know for the media lookup.
nonisolated extension ProgramIdentity {
    func idList(_ key: String) -> [String] { IDSpace.split(ids[key]) }
}

/// Keeps the hits of one source tidy: platforms normalised, empty strings dropped.
nonisolated extension ProgramHit {
    mutating func tidy() {
        platforms = Platforms.normalise(platforms)
        if developer?.isEmpty == true { developer = nil }
        if publisher?.isEmpty == true { publisher = nil }
        alternateTitles = Array(Set(alternateTitles.filter { !$0.isEmpty && $0 != title })).sorted()
        ids = ids.filter { !$0.value.isEmpty }
    }
}

nonisolated func remote(_ source: String, _ url: String, thumb: String? = nil, label: String?, kind: String? = nil, width: Int? = nil,
                        height: Int? = nil, region: String? = nil, title: String? = nil, page: String? = nil, license: String? = nil) -> RemoteMedia {
    var m = RemoteMedia(source: source, url: url)
    m.thumbUrl = thumb
    m.sourceLabel = label
    m.kind = kind ?? label.map(MediaLabels.kind)
    m.width = width
    m.height = height
    m.region = region
    m.title = title
    m.pageUrl = page
    m.license = license
    return m
}
