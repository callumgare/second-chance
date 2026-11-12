import Foundation
import IconLabKit

/// Programs, media, suggestions, rendering, documents and jobs (docs/api.md).
nonisolated extension IconLabAPI {
    static func addLabRoutes(_ router: inout Router, lab: Lab) {
        router.get("/api/programs") { _ in try json(await lab.programs()) }
        router.get("/api/programs/:slug") { c in try json(try await lab.program(try c.param("slug"))) }
        // Programs that are one program (a search result opened as both): the others' pictures, designs and pins
        // move into this one, and they're removed.
        router.post("/api/programs/:slug/absorb") { c in
            let slug = try c.param("slug")
            guard await lab.store.program(slug) != nil else { throw APIError.notFound }
            for other in try decode(AbsorbBody.self, c.request).from where other != slug {
                guard let p = await lab.store.program(other) else { continue }
                try await lab.store.absorb(other, into: slug)
                if var into = await lab.store.program(slug) {
                    into.ids = (into.ids ?? [:]).merging(p.ids ?? [:]) { a, _ in a }
                    try await lab.store.saveProgram(into)
                }
            }
            return try json(await lab.programs().first { $0.slug == slug })
        }
        router.get("/api/programs/:slug/look") { c in try json(try await lab.look(try c.param("slug"))) }
        router.get("/api/treatments") { _ in try json(Treatments.info) }

        router.get("/api/programs/:slug/media/:id/:variant") { c in
            let (url, type) = try await lab.mediaFile(try c.param("slug"), try c.param("id"), try c.param("variant"))
            return try file(url, type: type)
        }

        router.patch("/api/programs/:slug/media/:id") { c in
            let slug = try c.param("slug"), id = try c.param("id")
            let patch = try decode(MediaPatch.self, c.request)
            guard var rec = await lab.store.mediaRecord(slug, id) else { throw APIError.notFound }
            if patch.kind != nil || patch.rotation != nil {
                rec = try await lab.patchPart(slug, id, "whole", Lab.PartPatch(picked: nil, kind: patch.kind, rotation: patch.rotation, name: nil, edges: nil))
            }
            if let p = patch.picked, p != rec.anyPicked { rec = try await lab.pickAll(slug, id, p) }
            if let h = patch.hidden {
                rec.hidden = h ? true : nil
                try await lab.store.upsertMedia(slug, rec)
            }
            return try json(lab.dto(slug, rec))
        }

        router.post("/api/programs/:slug/suggestions") { c in
            let slug = try c.param("slug")
            let b = try decode(SuggestBody.self, c.request)
            let media = await lab.partRecords(slug)
            // Usually quick. When it isn't (the first time, cutting every picked part out), it shows as a job with its
            // progress from the moment it's been going a second, and finishes with it.
            let tracker = SuggestionProgress()
            let assets = lab.assets
            let work = Task.detached {
                await Treatments.suggestions(program: slug, media: media, params: b.params ?? .init(), only: b.treatments,
                                             assets: assets, progress: { p, d in await tracker.set(p, d) })
            }
            let watcher = Task.detached {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                await lab.jobs.start(title: "Making suggestions", program: slug, group: "suggestions") { progress in
                    while await !tracker.done {
                        let (p, d) = await tracker.now
                        await progress(p, d)
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
            }
            let s = await work.value
            await tracker.finish()
            watcher.cancel()
            return try json(s)
        }

        router.post("/api/render/content") { c in
            let b = try decode(ContentBody.self, c.request)
            return try json(try await lab.renderContent(program: b.program, content: b.content, pixelWidth: b.pixelWidth,
                                                        canvasWidth: b.canvasWidth ?? 1, transform: b.transform))
        }

        router.post("/api/render/shape") { c in
            let b = try decode(ShapeBody.self, c.request)
            return try json(["url": try lab.renderShape(b.shape, size: b.size)])
        }

        router.post("/api/render/mask") { c in
            let b = try decode(MaskBody.self, c.request)
            return try json(["url": try await lab.renderMask(program: b.program, mask: b.mask, size: b.size)])
        }

        router.post("/api/render/icon") { c in
            let b = try decode(IconBody.self, c.request)
            if b.cachedOnly == true {
                guard let png = lab.composer.cached(b.doc, appearance: b.appearance ?? "light", size: b.size ?? 256) else { throw APIError.notFound }
                return try json(["url": "/api/cache/" + png.path.replacingOccurrences(of: lab.composer.cacheDir.path + "/", with: "")])
            }
            let r = try await lab.renderIcon(b.doc, appearance: b.appearance ?? "light", size: b.size ?? 256)
            return try json(["url": r.url, "icon": r.icon])
        }

        router.get("/api/cache/**") { c in
            let rel = String(c.request.path.dropFirst("/api/cache/".count))
            guard !rel.contains("..") else { throw APIError.badRequest }
            return try file(lab.composer.cacheDir.appendingPathComponent(rel), type: "image/png")
        }

        // Documents
        router.get("/api/programs/:slug/docs") { c in
            let slug = try c.param("slug")
            let docs = await lab.store.docs(slug).compactMap { try? JSONSerialization.jsonObject(with: $0) }
            let st = await lab.store.state(slug)
            let obj: [String: Any] = ["docs": docs, "pins": st.pins, "dropped": st.dropped.filter { st.pins.contains($0) },
                                      "current": st.current as Any? ?? NSNull()]
            return raw(try JSONSerialization.data(withJSONObject: obj))
        }

        router.put("/api/programs/:slug/docs/:id") { c in
            let slug = try c.param("slug"), id = try c.param("id")
            let data = c.request.body
            _ = try JSONDecoder().decode(Doc.self, from: data)   // it must be a document
            try await lab.store.saveDoc(slug, id: id, json: data)
            await lab.store.touch(slug)
            return raw(data)
        }

        router.put("/api/programs/:slug/current") { c in
            let slug = try c.param("slug")
            var st = await lab.store.state(slug)
            st.current = try decode(IdBody.self, c.request).id
            try await lab.store.saveState(slug, st)
            return raw(Data("{}".utf8))
        }

        router.post("/api/programs/:slug/pins") { c in
            let slug = try c.param("slug")
            let b = try decode(PinBody.self, c.request)
            var id = b.id ?? ""
            if let docValue = b.doc {
                // pin with the document: save it first, so a pin never points at a missing doc
                let data = try JSONEncoder().encode(docValue)
                let doc = try JSONDecoder().decode(Doc.self, from: data)
                try await lab.store.saveDoc(slug, id: doc.id, json: data)
                id = doc.id
            }
            guard !id.isEmpty else { throw APIError(400, "id or doc") }
            var st = await lab.store.state(slug)
            if !st.pins.contains(id) { st.pins.append(id) }
            try await lab.store.saveState(slug, st)
            return try json(["pins": st.pins])
        }

        // The pins in a new order (Design's strip and Review share it; Save and Save to bundle follow it). Ids that
        // aren't pins are ignored, and pins it leaves out keep their place after the rest.
        router.put("/api/programs/:slug/pins") { c in
            let slug = try c.param("slug")
            let order = try decode(PinsOrder.self, c.request).pins
            var st = await lab.store.state(slug)
            let named = order.filter { st.pins.contains($0) }
            st.pins = named + st.pins.filter { !named.contains($0) }
            try await lab.store.saveState(slug, st)
            return try json(["pins": st.pins])
        }

        // Which pins Review keeps: those it doesn't are listed (`dropped`), so a new pin is kept.
        router.put("/api/programs/:slug/dropped") { c in
            let slug = try c.param("slug")
            var st = await lab.store.state(slug)
            st.dropped = try decode(PinsOrder.self, c.request).pins.filter { st.pins.contains($0) }
            try await lab.store.saveState(slug, st)
            return try json(["dropped": st.dropped])
        }

        router.delete("/api/programs/:slug/pins/:id") { c in
            let slug = try c.param("slug"), id = try c.param("id")
            var st = await lab.store.state(slug)
            st.pins.removeAll { $0 == id }
            try await lab.store.saveState(slug, st)
            return try json(["pins": st.pins])
        }

        router.post("/api/programs/:slug/save") { c in
            let slug = try c.param("slug")
            let saved = try await lab.save(slug, ids: try decode(SaveBody.self, c.request).ids)
            return try json(["saved": saved])
        }

        router.get("/api/jobs") { _ in try json(await lab.jobs.all()) }
    }
}

// MARK: Bodies

nonisolated struct MediaPatch: Decodable { var picked: Bool?; var kind: String?; var rotation: Int?; var hidden: Bool? }
nonisolated struct PinsOrder: Decodable { var pins: [String] }
nonisolated struct AbsorbBody: Decodable { var from: [String] }
nonisolated struct SuggestBody: Decodable, Sendable { var params: SuggestionParams?; var treatments: [String]? }
nonisolated struct ContentBody: Decodable {
    var program: String
    var content: Content
    var pixelWidth: Int
    var canvasWidth: Double?
    var transform: Transform?
}
nonisolated struct ShapeBody: Decodable { var program: String?; var shape: Shape; var size: Int }
nonisolated struct MaskBody: Decodable { var program: String; var mask: Mask; var size: Int }
nonisolated struct IconBody: Decodable { var doc: Doc; var appearance: String?; var size: Int?; var cachedOnly: Bool? }
nonisolated struct IdBody: Decodable { var id: String }
nonisolated struct PinBody: Decodable { var id: String?; var doc: JSONValue? }
nonisolated struct SaveBody: Decodable { var ids: [String] }

/// How far a suggestions request has got, for its job.
actor SuggestionProgress {
    var p = 0.0, detail: String?, done = false
    var now: (Double, String?) { (p, detail) }
    func set(_ p: Double, _ d: String?) { self.p = p; detail = d }
    func finish() { done = true }
}
