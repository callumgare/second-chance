import Foundation
import IconLabKit
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.API")

/// Icon Lab's API (docs/api.md), with no web server in it: a host hands it each request and sends back the answer,
/// and passes on its events. The app's URL scheme handler is one host, `Tools/icon-lab/server` another.
///
/// Requests are answered off the main actor (`handle` is `@concurrent`), so a host on the main thread stays
/// responsive however long one takes.
nonisolated public final class IconLabAPI: Sendable {
    public let lab: Lab
    public let catalog: Catalog
    /// The page's files, served for any path that isn't the API's; nil serves none.
    public let webRoot: URL?

    /// The page built into this package's resources (`sc icon-lab build`), which a host serves unless it names
    /// another; nil when the build left none. Found where SwiftPM's `Bundle.module` looks (the app's resources, or
    /// beside the program), without its accessor, which is the main actor's.
    public static var bundledWebRoot: URL? {
        let bundleName = "IconLab_IconLabAPI.bundle"
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for place in places.compactMap({ $0 }) {
            for candidate in [place.appendingPathComponent(bundleName + "/web"),
                              place.appendingPathComponent(bundleName + "/Contents/Resources/web")]
            where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate
            }
        }
        // Beside the binary this code is in, or a few folders up from it (`swift test`: beside the .xctest bundle).
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { return nil }
        var folder = URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = folder.appendingPathComponent(bundleName + "/web")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) { return candidate }
            folder.deleteLastPathComponent()
        }
        return nil
    }
    let router: Router

    /// - Parameters:
    ///   - dataDir: where Icon Lab keeps everything: programs, caches, catalogue copies, models.
    ///   - env: keys and settings (`Env(file:)` reads a `.env` the host names).
    ///   - webRoot: the built page, served at `/`; by default the one in this package's resources.
    ///   - tools: the programs and places Icon Lab uses from outside (`LabTools`).
    ///   - host: the programs the host has bundles for, and where those bundles may be written (`LabHostInfo`).
    public convenience init(dataDir: URL, env: Env = Env(file: nil), webRoot: URL? = IconLabAPI.bundledWebRoot, tools: LabTools = LabTools(),
                            host: LabHostInfo = LabHostInfo()) {
        self.init(lab: Lab(dataDir: dataDir, env: env, tools: tools, host: host), webRoot: webRoot)
    }

    public init(lab: Lab, webRoot: URL? = IconLabAPI.bundledWebRoot) {
        self.lab = lab
        self.webRoot = webRoot
        let catalog = Catalog(lab: lab)
        self.catalog = catalog
        var router = Router()
        Self.addLabRoutes(&router, lab: lab)
        Self.addCatalogRoutes(&router, lab: lab, catalog: catalog)
        Self.addStageTwoRoutes(&router, lab: lab)
        Self.addModelRoutes(&router, lab: lab)
        Self.addHostRoutes(&router, lab: lab)
        self.router = router
    }

    /// The work the engine does once it starts, in the background: bringing in the first lab's games (from
    /// `importingV1From`, when given), dropping derived copies and analysing what hasn't been, warming each
    /// program's colours and thumbnails, refreshing the catalogue's local copies (`refreshingLocalCopies`), working
    /// out duplicates again, and reporting the models' changes as events.
    public func start(importingV1From v1: URL? = nil, refreshingLocalCopies: Bool = true) async {
        let lab = lab, catalog = catalog
        if let v1, FileManager.default.fileExists(atPath: v1.path) {
            do {
                let imported = try await Importer.importV1(gamesDir: v1, store: lab.store)
                if !imported.isEmpty { logger.notice("Imported from v1: \(imported.joined(separator: ", "))") }
            } catch {
                logger.error("Couldn't import the first lab's games from \(v1.path): \(error)")
            }
        }
        for p in await lab.store.programs() {
            await lab.dropDerivedCopies(p.slug)
            await lab.analyseMissing(p.slug)
            await lab.resumeDeepening(p.slug)
        }
        // Warm each program's cached colours and thumbnails, so opening one is instant.
        Task.detached {
            for p in await lab.store.programs() {
                await lab.fillHasAlpha(p.slug)
                do { _ = try await lab.program(p.slug) } catch { logger.warning("Couldn't warm \(p.slug): \(error)") }
            }
        }
        // local copies (LaunchBox, TheGamesDB, My Abandonware) that are missing or a week old download in the background
        if refreshingLocalCopies { Task.detached { await catalog.refreshLocalCopies() } }
        // duplicates are worked out again at start-up, so a change to how they're found reaches gathered programs
        Task.detached {
            for p in await lab.store.programs() {
                do { try await catalog.markDuplicates(p.slug) } catch { logger.warning("Couldn't mark \(p.slug)'s duplicates: \(error)") }
            }
        }
        // Every model status change is also a `model` event.
        await lab.models.store.onChange { status in
            do {
                let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status))
                await lab.jobs.broadcast(["type": "model", "model": o])
            } catch {
                logger.warning("Couldn't send \(status.name)'s status: \(error)")
            }
        }
    }

    /// Every event the engine sends (jobs, media, scans, searches, models), each a JSON object, for as long as the
    /// stream is listened to. Each listener gets its own stream, as each page's WebSocket did.
    public func events() async -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let jobs = lab.jobs
        let id = await jobs.listen { continuation.yield($0) }
        continuation.onTermination = { _ in Task { await jobs.unlisten(id) } }
        return stream
    }

    /// Answers a request: the API's routes, then the page's files for a `GET` nothing else answered.
    @concurrent
    public func handle(_ request: APIRequest) async -> APIResponse {
        var answer: APIResponse
        if let (handler, params) = router.resolve(request.method, request.path) {
            answer = await Self.guarded { try await handler(RouteContext(request: request, parameters: params)) }
        } else {
            answer = APIError.notFound.response
        }
        if answer.status == 404, request.method == "GET" || request.method == "HEAD", let webRoot {
            switch WebFiles.serve(request.path, from: webRoot) {
            case .some(.success(let file)): answer = file
            case .some(.failure(let error)): answer = error.response
            case .none: break
            }
        }
        if request.method == "HEAD" { answer.body = .empty }
        return answer
    }

    /// Turns what a route throws into its answer: its own status, not found, or a server error with what went wrong.
    static func guarded(_ f: () async throws -> APIResponse) async -> APIResponse {
        do { return try await f() } catch let e as APIError { return e.response } catch let e as IconLabError {
            if case .notFound = e { return APIError(404, e.description).response }
            logger.error("\(e.description)")
            return APIError(500, e.description).response
        } catch {
            logger.error("\(error)")
            return APIError(500, "\(error)").response
        }
    }
}

// MARK: Answers

nonisolated extension IconLabAPI {
    static func json<T: Encodable>(_ v: T, status: Int = 200) throws -> APIResponse {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return raw(try e.encode(v), status: status)
    }

    static func raw(_ d: Data, status: Int = 200, type: String = "application/json") -> APIResponse {
        APIResponse(status: status, headers: ["Content-Type": type, "Cache-Control": "no-store"], body: .data(d))
    }

    static func file(_ url: URL, type: String) throws -> APIResponse {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else { throw APIError.notFound }
        return APIResponse(status: 200, headers: ["Content-Type": type, "Cache-Control": "max-age=3600"], body: .file(url))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ req: APIRequest) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: req.body) } catch {
            throw APIError(400, "\(error)")
        }
    }
}
