import CryptoKit
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.HTTP")

// The sources' one way onto the network: a per-host rate limit (archive.org one request every 4 s, strictly one at a
// time, backing off on 429/5xx; Macintosh Repository 10 s per its robots.txt; polite defaults elsewhere), a
// descriptive User-Agent, timeouts, an on-disk response cache (`data/cache/http/`), robots.txt checks for the sites we
// read HTML from, and big downloads with progress (the local dumps).

nonisolated public enum HTTPCache: Sendable {
    case none
    case search          // 7 days
    case api             // 30 days
    case days(Double)

    var maxAge: TimeInterval? {
        switch self {
        case .none: return nil
        case .search: return 7 * 86400
        case .api: return 30 * 86400
        case .days(let d): return d * 86400
        }
    }
}

nonisolated public struct HTTPResult: Sendable {
    public var status: Int
    public var data: Data
    public var contentType: String?
    public var url: URL
    public var fromCache: Bool
    public var ok: Bool { (200..<300).contains(status) }

    public func json() throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw FetchError.badBody(url.absoluteString, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

nonisolated public enum FetchError: Error, CustomStringConvertible {
    case status(Int, String)
    case badBody(String, String)
    case robots(String)
    case tooBig(String, Int)
    case quota(String)

    public var description: String {
        switch self {
        case .status(let s, let u): return "HTTP \(s) from \(Self.redact(u))"
        case .badBody(let u, let b): return "unreadable answer from \(Self.redact(u)): \(b)"
        case .robots(let u): return "robots.txt disallows \(Self.redact(u))"
        case .tooBig(let u, let n): return "\(Self.redact(u)) is too big (\(n) bytes)"
        case .quota(let s): return s
        }
    }

    /// Drops query strings that may carry credentials from messages.
    static func redact(_ u: String) -> String {
        guard var c = URLComponents(string: u) else { return u }
        c.queryItems = c.queryItems?.map { q in
            ["devpassword", "sspassword", "client_secret", "devid", "ssid", "key", "api_key"].contains(q.name.lowercased()) ? URLQueryItem(name: q.name, value: "…") : q
        }
        return c.string ?? u
    }
}

/// How politely to treat a host.
nonisolated public struct HostPolicy: Sendable {
    public var interval: TimeInterval     // minimum gap between request starts
    public var concurrent: Int            // requests in flight at once
    public var retries: Int               // on 429 / 5xx
    public var backoff: TimeInterval      // first back-off when the host has no Retry-After

    public static func forHost(_ host: String) -> HostPolicy {
        let h = host.lowercased()
        func on(_ domain: String) -> Bool { h == domain || h.hasSuffix("." + domain) }
        if on("archive.org") { return .init(interval: 4, concurrent: 1, retries: 3, backoff: 30) }
        if on("macintoshrepository.org") { return .init(interval: 10, concurrent: 1, retries: 1, backoff: 60) }
        if on("myabandonware.com") || on("winworldpc.com") { return .init(interval: 3, concurrent: 1, retries: 1, backoff: 30) }
        if on("screenscraper.fr") { return .init(interval: 1.2, concurrent: 1, retries: 1, backoff: 30) }
        if on("api.igdb.com") { return .init(interval: 0.26, concurrent: 4, retries: 2, backoff: 2) }
        if on("query.wikidata.org") { return .init(interval: 1, concurrent: 1, retries: 2, backoff: 10) }
        if on("wikidata.org") || on("wikipedia.org") || on("wikimedia.org") { return .init(interval: 0.25, concurrent: 2, retries: 2, backoff: 5) }
        // image CDNs: many small files for one program
        if on("images.launchbox-app.com") || on("images.igdb.com") || on("gog-statics.com") || on("steamstatic.com")
            || on("cdn2.steamgriddb.com") || on("steamgriddb.com") || on("cdn.thegamesdb.net") || on("staticflickr.com") {
            return .init(interval: 0.25, concurrent: 2, retries: 1, backoff: 5)
        }
        return .init(interval: 1, concurrent: 1, retries: 2, backoff: 5)
    }

    /// Hosts that share a limit (every archive.org host is one archive.org).
    static func gateKey(_ host: String) -> String {
        let h = host.lowercased()
        for d in ["archive.org", "macintoshrepository.org", "screenscraper.fr", "myabandonware.com", "winworldpc.com"]
        where h == d || h.hasSuffix("." + d) { return d }
        return h
    }
}

/// One host's queue: requests start no closer than `interval` apart, at most `concurrent` at once, and not before a
/// back-off ends.
actor HostGate {
    let policy: HostPolicy
    private var next = Date.distantPast
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(policy: HostPolicy) { self.policy = policy }

    func acquire() async {
        while inFlight >= policy.concurrent {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight += 1
        let now = Date()
        let slot = max(next, now)
        next = slot.addingTimeInterval(policy.interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }

    func release() {
        inFlight -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Nothing starts on this host for `seconds`.
    func pause(_ seconds: TimeInterval) {
        next = max(next, Date().addingTimeInterval(seconds))
    }
}

/// Every HTTP client in the process shares these gates, so two parts of the engine can't together break a host's limit.
actor HostGates {
    static let shared = HostGates()
    private var gates: [String: HostGate] = [:]
    func gate(_ host: String) -> HostGate {
        let key = HostPolicy.gateKey(host)
        if let g = gates[key] { return g }
        let g = HostGate(policy: HostPolicy.forHost(host))
        gates[key] = g
        return g
    }
}

nonisolated public final class HTTP: Sendable {
    public static let userAgent = "SecondChanceIconLab/0.2 (personal icon-design tool for Second Chance; one user, cached and rate-limited; +https://github.com/callumgare/second-chance)"
    public let cacheDir: URL
    let session: URLSession
    private let robots = RobotsCache()

    public init(cacheDir: URL) {
        self.cacheDir = cacheDir
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = ["User-Agent": HTTP.userAgent]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Requests

    /// GET (or POST with a body). Answers from the cache when it's fresh enough; caches 2xx answers, and 404s for
    /// search lookups (a miss is an answer too). Throws for other non-2xx statuses after backing off and retrying.
    public func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                      cache: HTTPCache = .api, checkRobots: Bool = false, cacheNotFound: Bool = false,
                      maxBytes: Int = 50_000_000, timeout: TimeInterval = 30) async throws -> HTTPResult {
        let key = cacheKey(url, method: method, body: body)
        if let maxAge = cache.maxAge, let hit = cached(key, url: url, maxAge: maxAge) { return hit }
        if checkRobots, !(await robotsAllow(url)) { throw FetchError.robots(url.absoluteString) }
        let r = try await send(url, method: method, headers: headers, body: body, maxBytes: maxBytes, timeout: timeout)
        if cache.maxAge != nil, r.ok || (cacheNotFound && r.status == 404) { store(key, r) }
        if !r.ok, !(cacheNotFound && r.status == 404) { throw FetchError.status(r.status, url.absoluteString) }
        return r
    }

    public func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                     cache: HTTPCache = .api) async throws -> Any {
        try await fetch(url, method: method, headers: headers, body: body, cache: cache).json()
    }

    /// The raw request through the host's gate, with back-off and retries on 429 / 5xx.
    func send(_ url: URL, method: String, headers: [String: String], body: Data?, maxBytes: Int, timeout: TimeInterval) async throws -> HTTPResult {
        let gate = await HostGates.shared.gate(url.host ?? "")
        var attempt = 0
        while true {
            await gate.acquire()
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.httpMethod = method
            req.httpBody = body
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let result: Result<(Data, HTTPURLResponse), Error>
            do {
                let (d, resp) = try await session.data(for: req)
                result = .success((d, resp as? HTTPURLResponse ?? HTTPURLResponse()))
            } catch { result = .failure(error) }
            await gate.release()
            let (data, resp) = try result.get()
            let status = resp.statusCode
            if status == 429 || (500...599).contains(status) {
                let retryAfter = (resp.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                let wait = min(600, retryAfter ?? gate.policy.backoff * pow(2, Double(attempt)))
                await gate.pause(wait)
                if attempt < gate.policy.retries {
                    attempt += 1
                    continue
                }
            }
            guard data.count <= maxBytes else { throw FetchError.tooBig(url.absoluteString, data.count) }
            return HTTPResult(status: status, data: data, contentType: resp.value(forHTTPHeaderField: "Content-Type"),
                              url: resp.url ?? url, fromCache: false)
        }
    }

    // MARK: Cache

    struct CacheMeta: Codable { var url: String; var status: Int; var stored: Date; var contentType: String? }

    func cacheKey(_ url: URL, method: String, body: Data?) -> String {
        var d = Data("\(method) \(url.absoluteString)".utf8)
        if let body { d.append(body) }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    func cacheFiles(_ key: String, url: URL) -> (URL, URL) {
        let dir = cacheDir.appendingPathComponent(HostPolicy.gateKey(url.host ?? "other"))
        return (dir.appendingPathComponent("\(key).body"), dir.appendingPathComponent("\(key).json"))
    }

    func cached(_ key: String, url: URL, maxAge: TimeInterval) -> HTTPResult? {
        let (bodyFile, metaFile) = cacheFiles(key, url: url)
        guard let md = try? Data(contentsOf: metaFile), let meta = try? JSONDecoder.iso.decode(CacheMeta.self, from: md),
              Date().timeIntervalSince(meta.stored) < maxAge, let body = try? Data(contentsOf: bodyFile) else { return nil }
        return HTTPResult(status: meta.status, data: body, contentType: meta.contentType, url: URL(string: meta.url) ?? url, fromCache: true)
    }

    func store(_ key: String, _ r: HTTPResult) {
        let (bodyFile, metaFile) = cacheFiles(key, url: r.url)
        let meta = CacheMeta(url: FetchError.redact(r.url.absoluteString), status: r.status, stored: Date(), contentType: r.contentType)
        do {
            try FileManager.default.createDirectory(at: bodyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try r.data.write(to: bodyFile, options: .atomic)
            try JSONEncoder.iso.encode(meta).write(to: metaFile, options: .atomic)
        } catch {
            logger.warning("Couldn't cache \(meta.url): \(error)")
        }
    }

    // MARK: robots.txt

    public func robotsAllow(_ url: URL) async -> Bool {
        guard let host = url.host, let scheme = url.scheme, let robotsURL = URL(string: "\(scheme)://\(host)/robots.txt") else { return false }
        if let rules = await robots.rules(host) { return Robots.allows(rules, path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? "")) }
        let text: String
        do {
            let r = try await fetch(robotsURL, cache: .days(7), cacheNotFound: true)
            text = r.status == 404 ? "" : r.text
        } catch { return false }   // can't tell: don't
        let rules = Robots.parse(text)
        await robots.set(host, rules)
        return Robots.allows(rules, path: url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? ""))
    }

    // MARK: Big downloads

    /// Downloads a big file (a dump) to `dest` with progress, through the host's gate. Sends If-Modified-Since when
    /// `dest` exists; returns false when the server says it hasn't changed.
    public func download(_ url: URL, to dest: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Bool {
        let gate = await HostGates.shared.gate(url.host ?? "")
        await gate.acquire()
        defer { Task { await gate.release() } }
        var req = URLRequest(url: url, timeoutInterval: 60)
        if let mod = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate]) as? Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            req.setValue(f.string(from: mod), forHTTPHeaderField: "If-Modified-Since")
        }
        let delegate = DownloadProgress(progress)
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": HTTP.userAgent]
        config.timeoutIntervalForResource = 3600
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        let (tmp, resp) = try await s.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 304 { try? FileManager.default.removeItem(at: tmp); return false }
        guard (200..<300).contains(status) else { try? FileManager.default.removeItem(at: tmp); throw FetchError.status(status, url.absoluteString) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        if let lm = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified"), let d = HTTP.httpDate(lm) {
            try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: dest.path)
        }
        return true
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}

nonisolated final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64, Int64?) -> Void
    init(_ report: @escaping @Sendable (Int64, Int64?) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

actor RobotsCache {
    private var byHost: [String: [Robots.Rule]] = [:]
    func rules(_ host: String) -> [Robots.Rule]? { byHost[host] }
    func set(_ host: String, _ r: [Robots.Rule]) { byHost[host] = r }
}

/// The parts of robots.txt that matter to us: the `*` group's Allow / Disallow lines (with `*` and `$`).
nonisolated public enum Robots {
    public struct Rule: Sendable, Equatable { public var allow: Bool; public var pattern: String }

    public static func parse(_ text: String) -> [Rule] {
        var rules: [Rule] = [], inStar = false, lastWasAgent = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if field == "user-agent" {
                if !lastWasAgent { inStar = false }
                if value == "*" { inStar = true }
                lastWasAgent = true
                continue
            }
            lastWasAgent = false
            guard inStar else { continue }
            if field == "disallow", !value.isEmpty { rules.append(Rule(allow: false, pattern: value)) }
            if field == "allow", !value.isEmpty { rules.append(Rule(allow: true, pattern: value)) }
        }
        return rules
    }

    /// Longest matching rule wins; allowed when nothing matches.
    public static func allows(_ rules: [Rule], path: String) -> Bool {
        var best: Rule?
        for r in rules where matches(r.pattern, path) {
            guard let b = best else { best = r; continue }
            if r.pattern.count > b.pattern.count || (r.pattern.count == b.pattern.count && r.allow) { best = r }
        }
        return best?.allow ?? true
    }

    static func matches(_ pattern: String, _ path: String) -> Bool {
        var p = pattern
        let anchored = p.hasSuffix("$")
        if anchored { p.removeLast() }
        let rx = "^" + p.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + (anchored ? "$" : "")
        return path.range(of: rx, options: .regularExpression) != nil
    }
}

nonisolated extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

nonisolated extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

// MARK: Small helpers for reading JSON and building URLs

typealias JSONObject = [String: Any]

nonisolated extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s.isEmpty ? nil : s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func arr(_ k: String) -> [JSONObject] { self[k] as? [JSONObject] ?? [] }
    func strings(_ k: String) -> [String] { self[k] as? [String] ?? [] }
}

nonisolated extension URL {
    /// `base` with query items appended (values percent-encoded properly, `+` included).
    static func make(_ base: String, _ query: [(String, String)] = []) -> URL {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? "" }
        let q = query.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
        let s = q.isEmpty ? base : base + (base.contains("?") ? "&" : "?") + q
        return URL(string: s) ?? URL(string: base) ?? URL(string: "about:blank")!
    }
}

nonisolated extension CharacterSet {
    /// ASCII letters and digits (`.alphanumerics` includes every script's letters, which URLs don't allow raw).
    static let asciiAlphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    static let queryValue: CharacterSet = asciiAlphanumerics.union(CharacterSet(charactersIn: "-._~"))
    static let pathSegment: CharacterSet = asciiAlphanumerics.union(CharacterSet(charactersIn: "-._~"))
}

/// The first plausible year (1970–2039) in a string.
nonisolated func firstYear(_ s: String?) -> Int? {
    guard let s else { return nil }
    let chars = Array(s.utf8)
    guard chars.count >= 4 else { return nil }
    for i in 0...(chars.count - 4) {
        if i > 0, (48...57).contains(chars[i - 1]) { continue }
        if i + 4 < chars.count, (48...57).contains(chars[i + 4]) { continue }
        let slice = chars[i..<(i + 4)]
        guard slice.allSatisfy({ (48...57).contains($0) }), let y = Int(String(decoding: slice, as: UTF8.self)), (1970...2039).contains(y) else { continue }
        return y
    }
    return nil
}

nonisolated extension URL {
    /// A URL from text the code puts together: an error rather than a crash when it isn't one.
    static func required(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw IconLabError.invalid("URL \(string)") }
        return url
    }
}
