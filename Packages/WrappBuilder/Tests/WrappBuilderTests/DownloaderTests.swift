import Foundation
import CryptoKit
import Synchronization
import Testing
@testable import WrappBuilder

/// A web of our own: each URL's answers in turn, and the requests made.
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    static let answers = Mutex<[String: [Answer]]>([:])
    static let requests = Mutex<[URLRequest]>([])

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let url = request.url?.absoluteString ?? ""
        let answer = Self.answers.withLock { answers -> Answer in
            guard var list = answers[url], !list.isEmpty else { return Answer(status: 404, body: Data()) }
            let first = list.removeFirst()
            answers[url] = list.isEmpty ? [first] : list
            return first
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct DownloaderTests {
    let game = Data("the genuine game".utf8)
    var sha: String { SHA256.hash(data: game).map { String(format: "%02x", $0) }.joined() }

    private func downloader(_ answers: [String: [StubProtocol.Answer]]) throws -> (Downloader, URL) {
        StubProtocol.answers.withLock { $0 = answers }
        StubProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        return (Downloader(cache: cache, session: URLSession(configuration: configuration), userAgent: "SecondChanceTests",
                           longestWait: 0.05), cache)
    }

    @Test("The hash alone decides: a page that came back 200 is not the file, and the next URL is tried")
    func hashDecides() async throws {
        let (downloader, cache) = try downloader([
            "https://maker.example/game.exe": [.init(status: 200, body: Data("<html>gone</html>".utf8))],
            "https://archive.example/game.exe": [.init(status: 200, body: game)],
        ])
        defer { try? FileManager.default.removeItem(at: cache) }
        let request = DownloadRequest(urls: [URL(string: "https://maker.example/game.exe")!, URL(string: "https://archive.example/game.exe")!],
                                      sha256: sha)
        let download = try await downloader.fetch(request)
        #expect(try Data(contentsOf: download.file) == game)
        #expect(download.from?.host == "archive.example")
        #expect(download.failures.map(\.url.host) == ["maker.example"])
        #expect(StubProtocol.requests.withLock { $0.first?.value(forHTTPHeaderField: "User-Agent") } == "SecondChanceTests")

        // Once per Mac: the second fetch asks nobody.
        StubProtocol.requests.withLock { $0 = [] }
        let again = try await downloader.fetch(request)
        #expect(again.from == nil)
        #expect(StubProtocol.requests.withLock { $0.isEmpty })
    }

    @Test("When no URL has it, every one is reported")
    func unavailable() async throws {
        let (downloader, cache) = try downloader([:])
        defer { try? FileManager.default.removeItem(at: cache) }
        let urls = [URL(string: "https://a.example/x")!, URL(string: "https://b.example/x")!]
        do {
            _ = try await downloader.fetch(DownloadRequest(urls: urls, sha256: sha))
            Issue.record("expected it to fail")
        } catch let error as DownloadError {
            #expect(error.kind == .unavailable)
            #expect(error.failures.map(\.url) == urls)
        }
    }

    @Test("An interrupted download is resumed from where it stopped")
    func resumes() async throws {
        let half = game.count / 2
        let (downloader, cache) = try downloader([
            "https://maker.example/game.exe": [.init(status: 206, body: game.suffix(from: half))],
        ])
        defer { try? FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try game.prefix(half).write(to: cache.appendingPathComponent(sha + ".partial"))
        let download = try await downloader.fetch(DownloadRequest(urls: [URL(string: "https://maker.example/game.exe")!], sha256: sha))
        #expect(try Data(contentsOf: download.file) == game)
        #expect(StubProtocol.requests.withLock { $0.first?.value(forHTTPHeaderField: "Range") } == "bytes=\(half)-")
    }

    @Test("A site that says it's busy is waited for, as Retry-After says")
    func busy() async throws {
        let (downloader, cache) = try downloader([
            "https://maker.example/game.exe": [
                .init(status: 429, body: Data(), headers: ["Retry-After": "0"]),
                .init(status: 200, body: game),
            ],
        ])
        defer { try? FileManager.default.removeItem(at: cache) }
        let download = try await downloader.fetch(DownloadRequest(urls: [URL(string: "https://maker.example/game.exe")!], sha256: sha))
        #expect(download.failures.isEmpty)
        #expect(StubProtocol.requests.withLock { $0.count } == 2)
    }
}
