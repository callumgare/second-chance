import CoreML
import Foundation
import Logging
import Testing
@testable import IconLabKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Tests")

/// What a live test found, for whoever runs it.
nonisolated func log(_ items: Any...) { logger.notice("\(items.map { "\($0)" }.joined(separator: " "))") }

/// Icon Lab's data: `$ICONLAB_DATA`, else the checkout's `.local/tools/icon-lab/data`, where the standalone lab kept it.
nonisolated enum TestData {
    static let dir = ProcessInfo.processInfo.environment["ICONLAB_DATA"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".local/tools/icon-lab/data")
}

/// Runs the real models on the lab's own images. Off unless ICONLAB_MODELS_LIVE=1: it downloads ~320 MB the first
/// time (into the data's models/, where the lab keeps them too) and takes a minute.
nonisolated enum Live {
    static let modelsDir = TestData.dir.appendingPathComponent("models")
    static let programs = TestData.dir.appendingPathComponent("programs")
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ICONLAB_MODELS_OUT"] ?? NSTemporaryDirectory())
        .appendingPathComponent("iconlab-models")
    static let on = ProcessInfo.processInfo.environment["ICONLAB_MODELS_LIVE"] == "1"
    static let jobs = Jobs(width: 2)
    static var models: Models { Models(store: ModelStore.shared(root: modelsDir), jobs: jobs) }
}

nonisolated func secs(_ t0: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(t0)) }

@Suite(.serialized, .enabled(if: Live.on, "set ICONLAB_MODELS_LIVE=1 to download and run the real models"))
struct ModelsLiveTests {
    @Test func classifyEveryImage() async throws {
        let models = Live.models
        let t0 = Date()
        _ = try await models.classify(Bitmap(width: 8, height: 8, fill: (255, 255, 255, 255)))
        log("first classification (loads both models, embeds the prompts): \(secs(t0))")
        var lines: [String] = []
        var embeddings: [(String, [Float])] = []
        let fm = FileManager.default
        for program in try fm.contentsOfDirectory(atPath: Live.programs.path).sorted() {
            let dir = Live.programs.appendingPathComponent(program).appendingPathComponent("media")
            for f in (try? fm.contentsOfDirectory(atPath: dir.path).sorted()) ?? [] {
                guard let b = Bitmap.load(dir.appendingPathComponent(f)) else { continue }
                let t = Date()
                let small = b.width * b.height > 4_000_000 ? b.resized(width: b.width * 1000 / max(b.width, b.height), height: b.height * 1000 / max(b.width, b.height)) : b
                let e = try await models.imageEmbedding(small)
                let k = try await models.classify(embedding: e)
                let kc = try await models.classify(embedding: models.imageEmbedding(small, fit: .crop))
                embeddings.append(("\(program)/\(f)", e))
                let top = k.prefix(3).map { "\($0.kind) \(Int(($0.probability * 100).rounded()))%" }.joined(separator: ", ")
                lines.append("\(program)/\(f)\t\(b.width)x\(b.height)\t\(top)\t(crop: \(kc[0].kind))\t\(secs(t))")
            }
        }
        log(lines.joined(separator: "\n"))
        // most similar pairs, to judge the embedding as a duplicate finder
        var pairs: [(Float, String, String)] = []
        for i in embeddings.indices { for j in embeddings.indices where j > i {
            pairs.append((Models.dot(embeddings[i].1, embeddings[j].1), embeddings[i].0, embeddings[j].0))
        } }
        for p in pairs.sorted(by: { $0.0 > $1.0 }).prefix(12) { log(String(format: "sim %.3f", p.0), p.1, "~", p.2) }
        let q = try await models.textEmbedding("a lighthouse")
        let best = embeddings.map { (Models.dot(q, $0.1), $0.0) }.sorted { $0.0 > $1.0 }.prefix(3)
        log("text search 'a lighthouse':", best.map { "\($0.1) \(String(format: "%.3f", $0.0))" })
    }

    @Test func cutOutAndUpscale() async throws {
        let models = Live.models
        try FileManager.default.createDirectory(at: Live.out, withIntermediateDirectories: true)
        let names = ["zoombinis/media/wikipedia-cover-7f82dd3c7d.jpg", "myst/media/wikipedia-cover-4a9a1887c0.png",
                     "zoombinis/media/ia-rarezoombinis-cover-52e2ea8c9a.jpg"]
                         + (ProcessInfo.processInfo.environment["ICONLAB_MODELS_EXTRA"]?.split(separator: ",").map(String.init) ?? [])
        for n in names {
            guard let b = Bitmap.load(Live.programs.appendingPathComponent(n)) else { log("missing \(n)"); continue }
            let stem = n.replacingOccurrences(of: "/media/", with: "-").replacingOccurrences(of: "/", with: "-")
            var t = Date()
            let mask = try await models.subjectMask(b)
            log("mask \(n) \(b.width)x\(b.height): \(secs(t))")
            t = Date()
            _ = try await models.subjectMask(b)
            log("  again: \(secs(t))")
            try mask.writePNG(to: Live.out.appendingPathComponent("\(stem)-mask.png"))
            var cut = b
            cut.multiplyAlpha(by: mask, luminance: true)
            try cut.writePNG(to: Live.out.appendingPathComponent("\(stem)-cutout.png"))
            t = Date()
            let up = try await models.upscale(b)
            log("upscale \(n) \(b.width)x\(b.height) -> \(up.width)x\(up.height): \(secs(t))")
            try up.writePNG(to: Live.out.appendingPathComponent("\(stem)-x4.png"))
            try b.resized(width: b.width * 4, height: b.height * 4).writePNG(to: Live.out.appendingPathComponent("\(stem)-plain-x4.png"))
        }
        log("written to \(Live.out.path)")
    }

    @Test func resumesAPartialDownload() async throws {
        // the first 300 kB of the tokenizer's vocabulary already here: only the rest should come over the network
        guard let spec = ModelManifest.spec(Models.clipTokenizer), let f = spec.files.first, let url = URL(string: f.url) else { return }
        let have = try await Live.models.store.ensure(Models.clipTokenizer, jobs: Live.jobs).appendingPathComponent(f.path)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent(f.path)
        try Data(contentsOf: have).prefix(300_000).write(to: dest.appendingPathExtension("part"))
        let counts = Counts()
        try await FileDownload.fetch(url, to: dest, size: f.size, sha256: f.sha256) { n in await counts.add(n) }
        #expect(try Data(contentsOf: dest) == Data(contentsOf: have))
        let seen = await counts.all
        log("progress reports:", seen)
        #expect(seen.allSatisfy { $0 > 300_000 })
    }
}

actor Counts {
    var all: [Int] = []
    func add(_ n: Int) { all.append(n) }
}
