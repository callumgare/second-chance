import Foundation
import IconLabKit

/// The machine-learning models: what's here, and fetching one ahead of need (docs/api.md, "Models"). Every status
/// change is also a `model` event (`IconLabAPI.start`).
nonisolated extension IconLabAPI {
    static func addModelRoutes(_ router: inout Router, lab: Lab) {
        let models = lab.models

        router.get("/api/models") { _ in try json(await models.store.statuses()) }

        router.post("/api/models/:name/download") { c in
            let name = try c.param("name")
            // Runs as a job; the answer is where it stands now (downloading, or ready already).
            guard let s = await models.store.startDownload(name, jobs: models.jobs) else { throw APIError(404, "no model \(name)") }
            return try json(s, status: 202)
        }

        router.delete("/api/models/:name") { c in
            let name = try c.param("name")
            guard ModelManifest.spec(name) != nil else { throw APIError(404, "no model \(name)") }
            try await models.store.remove(name)
            return try json(await models.store.status(name))
        }
    }
}
