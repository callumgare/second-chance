import Foundation
import IconLabKit

/// Picks, parts, hi-res downloads, upscaling, deep analysis and local files.
nonisolated extension IconLabAPI {
    static func addStageTwoRoutes(_ router: inout Router, lab: Lab) {
        router.post("/api/programs/:slug/media/:id/pick") { c in
            let slug = try c.param("slug"), id = try c.param("id")
            let rec = try await lab.pickAll(slug, id, try decode(PickBody.self, c.request).picked)
            return try json(lab.dto(slug, rec))
        }

        // Parts
        router.patch("/api/programs/:slug/media/:id/parts/:part") { c in
            let slug = try c.param("slug")
            let rec = try await lab.patchPart(slug, try c.param("id"), try c.param("part"), try decode(Lab.PartPatch.self, c.request))
            return try json(lab.dto(slug, rec))
        }
        router.delete("/api/programs/:slug/media/:id/parts/:part") { c in
            let slug = try c.param("slug")
            return try json(lab.dto(slug, try await lab.deletePart(slug, try c.param("id"), try c.param("part"))))
        }
        router.get("/api/programs/:slug/media/:id/parts/:part/:variant") { c in
            let url = try await lab.partFile(try c.param("slug"), try c.param("id"), try c.param("part"), try c.param("variant"))
            return try file(url, type: "image/png")
        }
        router.post("/api/programs/:slug/media/:id/parts/:part/cutouts") { c in
            try json(["job": try await lab.frameCutouts(try c.param("slug"), try c.param("id"), frame: try c.param("part"))])
        }
        router.post("/api/programs/:slug/media/:id/detect") { c in
            let b = try decode(RegionBody.self, c.request)
            guard b.region.count == 4 else { throw APIError(400, "region is [x, y, w, h]") }
            return try json(["candidates": try await lab.detect(try c.param("slug"), try c.param("id"), region: b.region)])
        }
        router.post("/api/programs/:slug/media/:id/segment") { c in
            let b = try decode(SegmentBody.self, c.request)
            guard !(b.points ?? []).isEmpty || b.region?.count == 4 else { throw APIError(400, "points or a region") }
            return try json(["candidates": try await lab.segment(try c.param("slug"), try c.param("id"), points: b.points ?? [], region: b.region)])
        }
        router.post("/api/programs/:slug/media/:id/candidates/:cand/preview") { c in
            let r = try await lab.previewCandidate(try c.param("slug"), try c.param("id"), try c.param("cand"),
                                                   edges: try decode(EdgesBody.self, c.request).edges)
            return try json(PreviewOut(url: r.url, box: r.box))
        }
        router.post("/api/programs/:slug/media/:id/parts") { c in
            let slug = try c.param("slug")
            let rec = try await lab.savePart(slug, try c.param("id"), replacing: nil, try decode(Lab.PartFromCandidate.self, c.request))
            return try json(lab.dto(slug, rec))
        }
        router.put("/api/programs/:slug/media/:id/parts/:part") { c in
            let slug = try c.param("slug")
            let rec = try await lab.savePart(slug, try c.param("id"), replacing: try c.param("part"), try decode(Lab.PartFromCandidate.self, c.request))
            return try json(lab.dto(slug, rec))
        }

        // Upscaling (design stage)
        router.post("/api/upscale") { c in
            let b = try decode(UpscaleBody.self, c.request)
            let r = try await lab.upscale(b.program, b.asset, mode: b.mode ?? "photo")
            let url = "/api/programs/\(b.program)/assets/\(r.asset.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? r.asset)/image"
            return try json(UpscaleOut(asset: r.asset, url: url, width: r.width, height: r.height))
        }
        router.get("/api/programs/:slug/assets/:asset/info") { c in
            let asset = try c.param("asset").removingPercentEncoding ?? ""
            return try json(try await lab.assetInfo(try c.param("slug"), asset))
        }
        router.get("/api/programs/:slug/assets/:asset/image") { c in
            let slug = try c.param("slug"), asset = try c.param("asset").removingPercentEncoding ?? ""
            let img = try await lab.assets.image(slug, asset)
            guard let d = img.pngData() else { throw APIError.internalServerError }
            return raw(d, type: "image/png")
        }

        router.post("/api/programs/:slug/media/:id/deepen") { c in
            await lab.deepen(try c.param("slug"), try c.param("id"))
            return raw(Data("{}".utf8))
        }

        router.get("/api/programs/:slug/scans") { c in try json(lab.scans(try c.param("slug"))) }

        router.post("/api/programs/:slug/extract") { c in
            let scan = try await lab.extract(try c.param("slug"), path: try decode(ExtractBody.self, c.request).path)
            return try json(["scan": scan])
        }

        router.get("/api/fs") { c in
            let hidden = c.request.query("hidden") == "1"
            return try json(lab.listFiles(c.request.query("path"), showHidden: hidden))
        }
    }
}

nonisolated struct PickBody: Decodable { var picked: Bool }
nonisolated struct RegionBody: Decodable { var region: [Double] }
nonisolated struct SegmentBody: Decodable { var points: [Lab.SegmentPoint]?; var region: [Double]? }
nonisolated struct EdgesBody: Decodable { var edges: Edges }
nonisolated struct PreviewOut: Encodable { var url: String; var box: [Double] }
nonisolated struct UpscaleBody: Decodable { var program: String; var asset: String; var mode: String? }
nonisolated struct UpscaleOut: Encodable { var asset: String; var url: String; var width: Int; var height: Int }
nonisolated struct ExtractBody: Decodable { var path: String }
