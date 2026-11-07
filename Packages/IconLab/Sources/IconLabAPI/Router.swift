import Foundation

/// What a route's handler gets: the request and the path's parameters.
nonisolated struct RouteContext: Sendable {
    let request: APIRequest
    let parameters: [String: String]

    /// A path parameter, as it was sent (still percent-encoded).
    func param(_ name: String) throws -> String {
        guard let v = parameters[name] else { throw APIError.badRequest }
        return v
    }
}

/// Routes by method and path pattern: `/api/programs/:slug` (`:name` takes one segment), `/api/cache/**` (the rest).
nonisolated struct Router: Sendable {
    typealias Handler = @Sendable (RouteContext) async throws -> APIResponse

    private enum Segment: Equatable, Sendable {
        case literal(String)
        case parameter(String)
        case rest

        /// Literal segments are tried before parameters, and parameters before the rest, as the server's router did.
        var rank: Int {
            switch self {
            case .literal: 0
            case .parameter: 1
            case .rest: 2
            }
        }
    }

    private struct Route: Sendable {
        let method: String
        let pattern: [Segment]
        let handler: Handler
    }

    private var routes: [Route] = []

    mutating func add(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        let segments: [Segment] = pattern.split(separator: "/").map {
            if $0 == "**" { return .rest }
            if $0.hasPrefix(":") { return .parameter(String($0.dropFirst())) }
            return .literal(String($0))
        }
        routes.append(Route(method: method, pattern: segments, handler: handler))
    }

    mutating func get(_ p: String, _ h: @escaping Handler) { add("GET", p, h) }
    mutating func post(_ p: String, _ h: @escaping Handler) { add("POST", p, h) }
    mutating func put(_ p: String, _ h: @escaping Handler) { add("PUT", p, h) }
    mutating func patch(_ p: String, _ h: @escaping Handler) { add("PATCH", p, h) }
    mutating func delete(_ p: String, _ h: @escaping Handler) { add("DELETE", p, h) }

    /// The handler for a request and its parameters; nil when no route has the path, or none of the path's routes
    /// takes the method.
    func resolve(_ method: String, _ path: String) -> (Handler, [String: String])? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var best: (pattern: [Segment], params: [String: String])?
        for r in routes {
            guard let params = Self.match(r.pattern, parts) else { continue }
            if let b = best, !Self.ranksBefore(r.pattern, b.pattern) { continue }
            best = (r.pattern, params)
        }
        guard let best, let route = routes.first(where: { $0.pattern == best.pattern && $0.method == method }) else { return nil }
        return (route.handler, best.params)
    }

    private static func match(_ pattern: [Segment], _ parts: [String]) -> [String: String]? {
        var params: [String: String] = [:]
        for (i, seg) in pattern.enumerated() {
            switch seg {
            case .rest:
                return i < parts.count ? params : nil
            case .literal(let l):
                guard i < parts.count, parts[i] == l else { return nil }
            case .parameter(let name):
                guard i < parts.count else { return nil }
                params[name] = parts[i]
            }
        }
        return pattern.count == parts.count ? params : nil
    }

    /// Whether `a` is the more specific pattern: the first segment where they differ is a literal in `a`.
    private static func ranksBefore(_ a: [Segment], _ b: [Segment]) -> Bool {
        for (x, y) in zip(a, b) where x.rank != y.rank { return x.rank < y.rank }
        return false
    }
}
