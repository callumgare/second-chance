import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import IconLabAPI
import IconLabKit
import Logging
import NIOCore

// icon-lab-server --data <dir> [--port 8767] [--env <file>] [--web <dir>] [--ictool <path>] [--built-apps <dir>]
//                 [--bundles <dir>] [--v1 <games dir>] [--no-refresh]
//
// Serves Icon Lab's API (Packages/IconLab/docs/api.md) on 127.0.0.1, the page from --web, and the API's events on the
// /api/events WebSocket. --env defaults to the checkout's .env; --web to the page built into IconLabAPI's resources
// (`sc icon-lab build`); ictool to Xcode's; --built-apps to the checkout's built-apps/. --bundles names a Bundles/
// folder whose programs are listed first and whose bundles designs can be saved to (none by default, so nothing
// writes to the checkout's own unless asked). --no-refresh leaves the catalogue's local copies as they are. `sc icon-lab serve` runs this with Vite's dev server in front.

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Server")

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// The checkout this was built from: Tools/icon-lab/server/Sources/icon-lab-server/main.swift → the checkout.
let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

guard let data = option("--data") else {
    logger.critical("Say where Icon Lab's data is: --data <dir>")
    exit(64)
}
let port = Int(option("--port") ?? "") ?? 8767
let dataDir = URL(fileURLWithPath: data)
let envFile = URL(fileURLWithPath: option("--env") ?? checkout.appendingPathComponent(".env").path)
let webDir = option("--web").map { URL(fileURLWithPath: $0) } ?? IconLabAPI.bundledWebRoot
var tools = LabTools.inCheckout(checkout)
if let p = option("--ictool") { tools.ictool = p }
if let p = option("--built-apps") { tools.builtApps = URL(fileURLWithPath: p) }
var host = LabHostInfo()
if let p = option("--bundles") {
    let bundles = URL(fileURLWithPath: p)
    host = LabHostInfo(knownPrograms: KnownProgram.read(bundles: bundles), bundles: bundles)
}

let api = IconLabAPI(dataDir: dataDir, env: Env(file: envFile), webRoot: webDir, tools: tools, host: host)
await api.start(importingV1From: option("--v1").map { URL(fileURLWithPath: $0) }, refreshingLocalCopies: !args.contains("--no-refresh"))

/// Hands every request to the API.
nonisolated struct APIMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let api: IconLabAPI
    let files = FileIO()

    func handle(_ request: Request, context: Context, next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        var parts = URLComponents()
        parts.percentEncodedQuery = request.uri.query
        var headers: [String: String] = [:]
        for field in request.headers { headers[field.name.canonicalName] = field.value }
        let body = try await request.body.collect(upTo: 64 * 1024 * 1024)
        let answer = await api.handle(APIRequest(method: request.method.rawValue, path: request.uri.path, query: parts.queryItems ?? [],
                                                 headers: headers, body: Data(body.readableBytesView)))
        var fields = HTTPFields()
        for (name, value) in answer.headers {
            if let n = HTTPField.Name(name) { fields[n] = value }
        }
        let status = HTTPResponse.Status(code: answer.status)
        switch answer.body {
        case .empty:
            return Response(status: status, headers: fields)
        case .data(let d):
            return Response(status: status, headers: fields, body: .init(byteBuffer: ByteBuffer(bytes: d)))
        case .file(let url):
            return Response(status: status, headers: fields, body: try await files.loadFile(path: url.path, context: context))
        }
    }
}

let router = Router()
router.add(middleware: APIMiddleware(api: api))

let events = Router(context: BasicWebSocketRequestContext.self)
events.ws("/api/events") { inbound, outbound, _ in
    let stream = await api.events()
    let writer = Task {
        for await d in stream {
            do { try await outbound.write(.text(String(decoding: d, as: UTF8.self))) } catch { break }
        }
    }
    for try await _ in inbound {}
    writer.cancel()
}

let app = Application(router: router, server: .http1WebSocketUpgrade(webSocketRouter: events),
                      configuration: .init(address: .hostname("127.0.0.1", port: port)))
logger.notice("Icon Lab on http://127.0.0.1:\(port)/  (data: \(dataDir.path))")
try await app.runService()
