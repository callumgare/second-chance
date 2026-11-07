import Foundation
import IconLabKit

/// The host's programs and wrapps: listing them, opening one, trying a design on a wrapp, saving designs to a
/// bundle, and cancelling a job (docs/api.md, "The host's programs").
nonisolated extension IconLabAPI {
    static func addHostRoutes(_ router: inout Router, lab: Lab) {
        router.get("/api/host") { _ in
            try json(HostInfo(knownPrograms: lab.host.knownPrograms.count, wrapps: lab.tools.builtApps != nil, saveToBundle: lab.host.bundles != nil))
        }

        router.get("/api/known-programs") { _ in try json(await lab.knownPrograms()) }

        router.post("/api/known-programs/open") { c in
            let id = try decode(KnownBody.self, c.request).id
            let (slug, created) = try await lab.openKnown(id)
            return try json(["slug": slug], status: created ? 201 : 200)
        }

        router.get("/api/wrapps") { _ in try json(lab.wrapps()) }

        router.post("/api/programs/:slug/try-icon") { c in
            let slug = try c.param("slug")
            let b = try decode(TryBody.self, c.request)
            let doc: Data
            if let value = b.doc {
                doc = try JSONEncoder().encode(value)
            } else if let id = b.id, let saved = await lab.store.doc(slug, id) {
                doc = saved
            } else {
                throw APIError(400, "id of a saved design, or doc")
            }
            return try json(try await refused { try await lab.tryIcon(slug, doc: doc, on: b.wrapp, anywhere: b.anywhere ?? false) })
        }

        router.post("/api/programs/:slug/save-to-bundle") { c in
            let slug = try c.param("slug")
            let ids = try decode(SaveBody.self, c.request).ids
            return try json(try await refused { try await lab.saveToBundle(slug, ids: ids) })
        }

        router.post("/api/programs/:slug/save-to-bundle/lines") { c in
            let slug = try c.param("slug")
            return try json(["added": try await refused { try await lab.addIconLines(slug) }])
        }

        router.post("/api/jobs/:id/cancel") { c in
            try json(["cancelled": await lab.jobs.cancel(try c.param("id"))])
        }
    }
}

nonisolated extension IconLabAPI {
    /// What the engine refuses as invalid (not a built wrapp, no bundle to save to) is the request's fault: a 400.
    static func refused<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch IconLabError.invalid(let why) { throw APIError(400, why) }
    }
}

nonisolated struct HostInfo: Encodable { var knownPrograms: Int; var wrapps: Bool; var saveToBundle: Bool }
nonisolated struct KnownBody: Decodable { var id: String }
nonisolated struct TryBody: Decodable { var id: String?; var doc: JSONValue?; var wrapp: String; var anywhere: Bool? }
