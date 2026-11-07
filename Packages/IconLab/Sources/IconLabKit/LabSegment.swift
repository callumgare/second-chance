import Foundation

nonisolated extension Lab {
    /// SAM 2.1: three candidates for points and/or a region, ordered small part → whole object.
    public func segment(_ slug: String, _ id: String, points: [SegmentPoint], region: [Double]?) async throws -> [Candidate] {
        guard let rec = await store.mediaRecord(slug, id) else { throw IconLabError.notFound("media \(id)") }
        let pic = try await assets.image(slug, id)
        let masks = try await models.segment(pic, key: "\(slug)/\(id)@\(rec.file)",
                                             points: points.map { (x: $0.x, y: $0.y, positive: $0.positive) }, region: region)
        var out: [Candidate] = []
        for m in masks.sorted(by: { $0.sizeRank < $1.sizeRank }) { out.append(try await candidate(slug, id, mask: m.mask, score: m.score)) }
        return out
    }
}
