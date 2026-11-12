import Foundation
import Testing
@testable import IconLabAPI
@testable import IconLabKit

/// The API without a server: routes, errors and the page's files, over an empty data folder.
@Suite final class APITests {
    let root: URL
    let api: IconLabAPI

    deinit {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("couldn't remove \(root.path): \(error)") }
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-api-\(UUID().uuidString)")
        let web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<html>lab</html>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("let x = 1".utf8).write(to: web.appendingPathComponent("assets/app.js"))
        api = IconLabAPI(dataDir: root.appendingPathComponent("data"), webRoot: web)
    }

    func json(_ r: APIResponse) throws -> Any { try JSONSerialization.jsonObject(with: r.bodyData()) }

    @Test func listsNoProgramsInAnEmptyFolder() async throws {
        let r = await api.handle(APIRequest(method: "GET", path: "/api/programs"))
        #expect(r.status == 200)
        #expect(r.headers["Content-Type"] == "application/json")
        #expect((try json(r) as? [Any])?.isEmpty == true)
    }

    @Test func treatmentsAreListed() async throws {
        let r = await api.handle(APIRequest(method: "GET", path: "/api/treatments"))
        #expect(r.status == 200)
        #expect(try #require(json(r) as? [Any]).count == Treatments.info.count)
    }

    @Test func aMissingProgramIsNotFoundWithAMessage() async throws {
        let r = await api.handle(APIRequest(method: "GET", path: "/api/programs/nothing-here"))
        #expect(r.status == 404)
        let error = try #require((json(r) as? [String: Any])?["error"] as? [String: Any])
        #expect(error["message"] as? String == "not found: program nothing-here")
    }

    @Test func aBadBodyIsABadRequest() async throws {
        let r = await api.handle(APIRequest(method: "POST", path: "/api/search", body: Data("{".utf8)))
        #expect(r.status == 400)
        let empty = await api.handle(APIRequest(method: "POST", path: "/api/search", body: Data(#"{"q": "  "}"#.utf8)))
        #expect(empty.status == 400)
        #expect(String(decoding: try empty.bodyData(), as: UTF8.self) == #"{"error":{"message":"empty query"}}"#)
    }

    @Test func anUnknownPathOrMethodIsNotFound() async {
        #expect(await api.handle(APIRequest(method: "GET", path: "/api/nope")).status == 404)
        #expect(await api.handle(APIRequest(method: "DELETE", path: "/api/programs")).status == 404)
    }

    @Test func aDroppedPictureIsPickedAtTheTopAndClearedWithItsSource() async throws {
        try await api.lab.store.saveProgram(Store.ProgramInfo(slug: "demo", title: "Demo"))
        let png = try #require(Bitmap(width: 40, height: 30, fill: (200, 30, 30, 255)).pngData())
        let r = await api.handle(APIRequest(method: "POST", path: "/api/programs/demo/media/upload",
                                            query: [URLQueryItem(name: "name", value: "Box.png")], body: png))
        #expect(r.status == 201)
        let m = try #require(json(r) as? [String: Any])
        #expect(m["source"] as? String == "Your files")
        #expect(m["picked"] as? Bool == true)
        #expect(m["suitability"] as? Double == 5)
        #expect(m["width"] as? Int == 40)

        let notAPicture = await api.handle(APIRequest(method: "POST", path: "/api/programs/demo/media/upload", body: Data("hello".utf8)))
        #expect(notAPicture.status == 500)

        let cleared = await api.handle(APIRequest(method: "POST", path: "/api/programs/demo/clear", body: Data(#"{"sources": ["files"]}"#.utf8)))
        #expect((try json(cleared) as? [String: Any])?["removed"] as? Int == 1)
        #expect(await api.lab.store.media("demo").isEmpty)
    }

    @Test func servesThePage() async throws {
        let index = await api.handle(APIRequest(method: "GET", path: "/"))
        #expect(index.status == 200)
        #expect(index.headers["Content-Type"] == "text/html")
        #expect(String(decoding: try index.bodyData(), as: UTF8.self) == "<html>lab</html>")
        let script = await api.handle(APIRequest(method: "GET", path: "/assets/app.js"))
        #expect(script.headers["Content-Type"] == "text/javascript")
        #expect(await api.handle(APIRequest(method: "GET", path: "/assets")).status == 301)
        #expect(await api.handle(APIRequest(method: "GET", path: "/../secret")).status == 400)
        #expect(await api.handle(APIRequest(method: "GET", path: "/missing.js")).status == 404)
    }

    @Test func rendersAShapeAndServesIt() async throws {
        let body = Data(##"{"shape": {"type": "circle", "color": "#ff0000"}, "size": 64}"##.utf8)
        let r = await api.handle(APIRequest(method: "POST", path: "/api/render/shape", body: body))
        #expect(r.status == 200)
        let url = try #require((json(r) as? [String: String])?["url"])
        #expect(url.hasPrefix("/api/cache/shape/"))
        let png = await api.handle(APIRequest(method: "GET", path: url))
        #expect(png.status == 200)
        #expect(png.headers["Content-Type"] == "image/png")
        guard case .file = png.body else { Issue.record("a cached render is streamed from disk"); return }
    }

    @Test func eventsReachEveryListener() async throws {
        let a = await api.events(), b = await api.events()
        await api.lab.jobs.broadcast(["type": "test"])
        var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
        let ea = try #require(await ia.next()), eb = try #require(await ib.next())
        #expect(String(decoding: ea, as: UTF8.self) == #"{"type":"test"}"#)
        #expect(ea == eb)
    }

    @Test func queryItemsAreDecoded() throws {
        let r = APIRequest(method: "get", url: try #require(URL(string: "iconlab://app/api/fs?path=%2FUsers%2Fsome%20one&hidden=1")))
        #expect(r.method == "GET")
        #expect(r.path == "/api/fs")
        #expect(r.query("path") == "/Users/some one")
        #expect(r.query("hidden") == "1")
    }
}

@Suite struct RouterTests {
    func router() -> Router {
        var r = Router()
        r.get("/api/programs/:slug/media/:id/:variant") { _ in APIResponse(status: 1) }
        r.post("/api/programs/:slug/media/:id/pick") { _ in APIResponse(status: 2) }
        r.get("/api/cache/**") { _ in APIResponse(status: 3) }
        return r
    }

    @Test func parametersAreTakenAsSent() async throws {
        let (handler, params) = try #require(router().resolve("GET", "/api/programs/a%20b/media/m1/thumb"))
        #expect(params == ["slug": "a%20b", "id": "m1", "variant": "thumb"])
        #expect(try await handler(RouteContext(request: APIRequest(method: "GET", path: "/"), parameters: params)).status == 1)
    }

    @Test func aLiteralSegmentWinsOverAParameter() {
        #expect(router().resolve("POST", "/api/programs/s/media/m/pick") != nil)
        // the literal route is the path's, and it doesn't take GET
        #expect(router().resolve("GET", "/api/programs/s/media/m/pick") == nil)
    }

    @Test func theRestTakesEverySegment() {
        #expect(router().resolve("GET", "/api/cache/shape/abc.png") != nil)
        #expect(router().resolve("GET", "/api/cache") == nil)
    }
}
