import Foundation
import IconLabKit

/// Stage 1 search and stage 2 gathering (docs/api.md, "Search" and "Gathering").
nonisolated extension IconLabAPI {
    static func addCatalogRoutes(_ router: inout Router, lab: Lab, catalog: Catalog) {
        router.get("/api/sources") { _ in try json(await catalog.sources()) }

        router.post("/api/sources/refresh") { c in
            let b = (try? decode(RefreshBody.self, c.request)) ?? RefreshBody()
            await catalog.refreshLocalCopies(force: b.force ?? true)
            return try json(await catalog.sources())
        }

        router.post("/api/search") { c in
            let q = try decode(SearchBody.self, c.request).q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { throw APIError(400, "empty query") }
            return try json(["id": await catalog.search(q)])
        }

        router.get("/api/search/:id") { c in
            guard let s = await catalog.snapshot(try c.param("id")) else { throw APIError.notFound }
            return try json(s)
        }

        router.post("/api/programs") { c in
            let r = try decode(CreateBody.self, c.request).result
            let slug = try await catalog.createProgram(r)
            guard let s = await catalog.summary(slug) else { throw APIError.internalServerError }
            return try json(s, status: 201)
        }

        router.post("/api/programs/:slug/gather") { c in
            let slug = try c.param("slug")
            let b = (try? decode(GatherBody.self, c.request)) ?? GatherBody()
            return try json(["jobs": try await catalog.gather(slug, brave: b.brave ?? false, only: b.sources, clear: b.clear ?? false)])
        }
    }
}

nonisolated struct RefreshBody: Decodable { var force: Bool? }
nonisolated struct SearchBody: Decodable { var q: String }
nonisolated struct CreateBody: Decodable { var result: ProgramResult }
nonisolated struct GatherBody: Decodable { var brave: Bool?; var sources: [String]?; var clear: Bool? }
