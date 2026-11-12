import CoreML
import Foundation
import Testing
@testable import IconLabKit

@Suite(.serialized, .enabled(if: Live.on, "set ICONLAB_MODELS_LIVE=1 to download and run the real models"))
struct SegmenterLiveTests {
    @Test func describeSAM() async throws {
        for name in Segmenter.modelNames {
            let m = try await Live.models.store.model(name, jobs: Live.jobs).model
            log("== \(name)")
            for (k, v) in m.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) { log("  in  \(k): \(v)") }
            for (k, v) in m.modelDescription.outputDescriptionsByName.sorted(by: { $0.key < $1.key }) { log("  out \(k): \(v)") }
        }
    }

    @Test func clickOnFreddi() async throws {
        let models = Live.models
        let name = ProcessInfo.processInfo.environment["ICONLAB_SAM_IMAGE"] ?? "freddi-fish/media/wikipedia-cover-b9c5f25228.png"
        let img = try #require(Bitmap.load(Live.programs.appendingPathComponent(name)))
        let out = Live.out.appendingPathComponent("sam")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for m in Segmenter.modelNames { _ = try await models.store.model(m, jobs: Live.jobs) }   // loading isn't encoding

        let key = "live/\(name)@\(UUID().uuidString)"
        var t = Date()
        try await models.prepareSegmenting(img, key: key)
        log("encode \(img.width)x\(img.height) (first in process): \(secs(t))")
        t = Date()
        try await models.prepareSegmenting(img, key: key + "-again")
        log("encode again (warm): \(secs(t))")
        t = Date()
        let file = await SAMCache.shared(Live.modelsDir.deletingLastPathComponent().appendingPathComponent("cache/sam")).file(key)
        let fromDisk = SAMEncoding(try Data(contentsOf: file))
        log("read encoding from disk: \(secs(t)) (\(fromDisk != nil ? "ok" : "BAD"), \((try? Data(contentsOf: file).count) ?? 0) bytes)")

        let prompts: [(String, [Segmenter.Point], [Double]?)] = [
            ("face", [.init(x: 0.55, y: 0.55, positive: true)], nil),
            ("face-not-chest", [.init(x: 0.55, y: 0.55, positive: true), .init(x: 0.45, y: 0.3, positive: false)], nil),
            ("box", [], [0.15, 0.3, 0.75, 0.6]),
        ]
        for (label, pts, region) in prompts {
            t = Date()
            let masks = try await models.segment(img, key: key, points: pts, region: region)
            log("\(label): decode \(secs(t)) →", masks.map { String(format: "score %.2f area %.2f rank %d", $0.score, $0.area, $0.sizeRank) })
            for (i, m) in masks.enumerated() {
                try m.mask.writePNG(to: out.appendingPathComponent("\(label)-\(i)-mask.png"))
                var c = img
                c.multiplyAlpha(by: m.mask, luminance: true)
                try c.writePNG(to: out.appendingPathComponent("\(label)-\(i)-cut.png"))
            }
        }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: await SAMCache.shared(Live.modelsDir.deletingLastPathComponent().appendingPathComponent("cache/sam")).file(key + "-again"))
        log("written to \(out.path)")
    }
}
