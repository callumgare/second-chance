//
//  Downloader.swift
//  WrappBuilder
//
//  Fetching a download edition's input: from the first of its URLs whose
//  file has the bundle's hash, once per Mac, politely, resuming.

import Foundation
import CryptoKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappBuilder.Downloader")

/// What a download edition's input says to fetch (`source: download`): its
/// URLs in order, the file's SHA-256, which alone decides whether a URL has
/// it, and its size when known.
public nonisolated struct DownloadRequest: Sendable, Equatable {
    public let urls: [URL]
    public let sha256: String
    public let size: Int64?
    /// Headers every request sends: what a registry asks of anyone, such as
    /// GitHub's package registry's anonymous `Authorization: Bearer QQ==`.
    public let headers: [String: String]

    public init(urls: [URL], sha256: String, size: Int64? = nil, headers: [String: String] = [:]) {
        self.urls = urls
        self.sha256 = sha256.lowercased()
        self.size = size
        self.headers = headers
    }

    /// The input's request, from its manifest fields.
    public init(_ input: Manifest.Input) throws {
        guard let sha256 = input.sha256, let urls = input.urls, !urls.isEmpty else {
            throw DownloadError(kind: .notADownload, description: "\(input.id) has no urls and sha256")
        }
        self.init(urls: urls.compactMap(URL.init(string:)), sha256: sha256, size: input.size.map(Int64.init))
    }
}

public nonisolated struct DownloadError: Error, CustomStringConvertible, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No URL had the file, or none answered: what the person is told.
        case unavailable
        case notADownload
    }

    public let kind: Kind
    public let description: String
    /// Each URL that didn't give the file, and why.
    public var failures: [Download.Failure] = []
}

/// One fetch's outcome: the file, where it came from, and each URL tried
/// before it that didn't have it — which is reported, so a dead publisher
/// URL is noticed even when a mirror quietly takes over.
public nonisolated struct Download: Sendable, Equatable {
    public let file: URL
    /// The URL it came from; nil when it was in the cache already.
    public let from: URL?
    public let failures: [Failure]

    public struct Failure: Sendable, Equatable, CustomStringConvertible {
        public let url: URL
        public let reason: String
        public var description: String { "\(url.absoluteString): \(reason)" }
    }
}

/// Fetches download inputs into a cache keyed by their hash, so each file
/// is downloaded once per Mac (docs/wrapp-build.md#the-download-source). It
/// tries the URLs in order and takes the first whose file has the hash:
/// status codes and content types are ignored, since an archived page that
/// has gone can come back 200 with HTML, and a file that doesn't match
/// counts as "not here". One download at a time per site, a User-Agent
/// naming Second Chance, backing off on 429 and 503 as `Retry-After` says,
/// and an interrupted download resumed with `Range`.
public nonisolated final class Downloader: Sendable {
    public let cache: URL
    let session: URLSession
    let userAgent: String
    /// How many times a site saying it's busy (429, 503) is waited for.
    let busyRetries: Int
    /// The longest wait a `Retry-After` is taken at.
    let longestWait: TimeInterval
    private let sites = SiteQueue()

    public init(cache: URL, session: URLSession = .shared, userAgent: String, busyRetries: Int = 3, longestWait: TimeInterval = 120) {
        self.cache = cache
        self.session = session
        self.userAgent = userAgent
        self.busyRetries = busyRetries
        self.longestWait = longestWait
    }

    /// `~/Library/Caches/SecondChance/downloads`.
    public static func standardCache() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecondChance/downloads", isDirectory: true)
    }

    /// The cached file for `sha256`, if it has been downloaded.
    public func cached(_ sha256: String) -> URL? {
        let file = cache.appendingPathComponent(sha256.lowercased())
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The file `request` names: from the cache, or the first URL that has
    /// it. `progress` gets the bytes so far and the total when known.
    public func fetch(_ request: DownloadRequest,
                      progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> Download {
        if let file = cached(request.sha256) { return Download(file: file, from: nil, failures: []) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var failures: [Download.Failure] = []
        for url in request.urls {
            try Task.checkCancellation()
            do {
                let file = try await sites.one(at: url.host ?? "") {
                    try await self.download(url, request: request, progress: progress)
                }
                for failure in failures { logger.warning("[Download] \(failure)") }
                logger.notice("[Download] Got \(request.sha256.prefix(12))… from \(url.absoluteString)")
                return Download(file: file, from: url, failures: failures)
            } catch let error as CancellationError {
                throw error
            } catch {
                let failure = Download.Failure(url: url, reason: "\(error)")
                logger.warning("[Download] Not from \(url.absoluteString): \(failure.reason)")
                failures.append(failure)
            }
        }
        var error = DownloadError(kind: .unavailable, description: "no URL had the file with sha256 \(request.sha256)")
        error.failures = failures
        throw error
    }

    /// One URL's file, into the cache when its hash is right.
    private func download(_ url: URL, request: DownloadRequest,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let partial = cache.appendingPathComponent(request.sha256 + ".partial")
        let files = FileManager.default
        var busy = 0
        while true {
            var have = Int64((try? files.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0)
            var urlRequest = URLRequest(url: url)
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            if have > 0 { urlRequest.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            let (bytes, response) = try await session.bytes(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 429 || status == 503 {
                busy += 1
                guard busy <= busyRetries else { throw Reason("it stayed busy (\(status))") }
                let wait = min(Self.retryAfter(response) ?? Double(5 * busy), longestWait)
                logger.notice("[Download] \(url.host ?? "") is busy (\(status)): trying again in \(Int(wait)) s")
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            // A server that ignored the Range starts from the beginning.
            if status != 206, have > 0 {
                try? files.removeItem(at: partial)
                have = 0
            }
            if !files.fileExists(atPath: partial.path) { files.createFile(atPath: partial.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let total = request.size ?? ((response.expectedContentLength > 0) ? response.expectedContentLength + have : nil)
            var buffer = Data()
            buffer.reserveCapacity(1 << 16)
            var written = have
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written, total)
                    // A file bigger than the bundle says is the wrong one.
                    if let size = request.size, written > size { break }
                }
            }
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            progress(written, total)
            try handle.close()

            let hash = try LayerKey.hash(file: partial)
            guard hash == request.sha256 else {
                try? files.removeItem(at: partial)
                throw Reason("its file isn't the one wanted (sha256 \(hash.prefix(12))…, \(written) bytes)")
            }
            let file = cache.appendingPathComponent(request.sha256)
            try? files.removeItem(at: file)
            try files.moveItem(at: partial, to: file)
            return file
        }
    }

    /// `Retry-After` in seconds, when it's a number.
    static func retryAfter(_ response: URLResponse) -> TimeInterval? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    struct Reason: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// One download at a time from each site.
private actor SiteQueue {
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func one<T: Sendable>(at site: String, _ work: @Sendable () async throws -> T) async throws -> T {
        while busy.contains(site) {
            await withCheckedContinuation { waiting[site, default: []].append($0) }
        }
        busy.insert(site)
        defer {
            busy.remove(site)
            if var queue = waiting[site], !queue.isEmpty {
                queue.removeFirst().resume()
                waiting[site] = queue
            }
        }
        return try await work()
    }
}
