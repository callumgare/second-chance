import CoreML
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Models")

/// Zero-shot kinds with MobileCLIP-S2: the image's embedding against the embeddings of a few descriptions of each
/// kind. A kind's descriptions are averaged (CLIP's prompt ensembling), and a softmax over the kinds' cosine
/// similarities × 100 (CLIP's logit scale) gives each kind's probability.
nonisolated public enum KindPrompts {
    /// The descriptions for each of `MediaKind.all` (but `cutout`, which only the lab makes).
    public static let byKind: [(kind: String, prompts: [String])] = [
        ("box-front", ["the front cover of a software box", "a video game box cover", "the front of a boxed PC game", "the cover art of a computer game with its title"]),
        ("box-back", ["the back of a software box with screenshots and text", "the back cover of a video game box"]),
        ("box-spine", ["the narrow spine of a software box", "a tall thin strip from the side of a box"]),
        ("disc", ["a CD-ROM disc", "a compact disc label", "a floppy disk"]),
        ("logo", ["a game logo on a plain background", "a title wordmark"]),
        ("icon", ["a small pixel art program icon", "a computer desktop icon"]),
        ("title-screen", ["a video game title screen", "the title screen of a computer game"]),
        ("screenshot", ["a screenshot of a video game", "a screenshot of a computer program"]),
        ("banner", ["a wide promotional banner for a game", "a website header banner"]),
        ("manual", ["a page from a printed manual", "a scanned page of text"]),
        ("art", ["promotional artwork", "an illustration of a character"]),
        ("other", ["a photograph", "a diagram"]),
    ]
}

nonisolated extension Models {
    public static let clipImage = "mobileclip-s2-image"
    public static let clipText = "mobileclip-s2-text"
    public static let clipTokenizer = "clip-tokenizer"

    /// The image's MobileCLIP embedding: 512 numbers, unit length. Two images' dot product is their similarity
    /// (about 0.9 and up for the same art in two scans), and it's comparable with `textEmbedding`s.
    /// How a picture that isn't square is fitted to the model's square input.
    public enum Fit: Sendable { case crop, pad }

    public func imageEmbedding(_ image: Bitmap, fit: Fit = .pad) async throws -> [Float] {
        let lm = try await store.model(Self.clipImage, jobs: jobs)
        let m = lm.model
        guard let input = ModelIO.input(m, .image), let c = input.imageConstraint else {
            throw IconLabError.tool("\(Self.clipImage) has no image input")
        }
        let pb = try ModelIO.pixelBuffer(Self.fitted(image, side: c.pixelsWide, fit: fit))
        let out = try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.name: MLFeatureValue(pixelBuffer: pb)]))
        return try Self.firstEmbedding(out, m)
    }

    /// A text's MobileCLIP embedding, unit length. Kept on disk once worked out (`text-embeddings.json`).
    public func textEmbedding(_ text: String) async throws -> [Float] {
        try await textEmbeddings([text])[0]
    }

    public func textEmbeddings(_ texts: [String]) async throws -> [[Float]] {
        let cache = TextEmbeddingCache.shared(store.root.appendingPathComponent("\(Self.clipText)-embeddings.json"))
        var out: [[Float]?] = await texts.asyncMap { await cache.get($0) }
        if out.contains(where: { $0 == nil }) {
            let lm = try await store.model(Self.clipText, jobs: jobs)
            let tokenizer = try await TokenizerCache.shared.tokenizer(try await store.ensure(Self.clipTokenizer, jobs: jobs))
            guard let input = ModelIO.input(lm.model, .multiArray) else { throw IconLabError.tool("\(Self.clipText) has no token input") }
            for (i, t) in texts.enumerated() where out[i] == nil {
                let ids = tokenizer.tokenize(t)
                let a = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: input.multiArrayConstraint?.dataType ?? .int32)
                for (j, id) in ids.enumerated() { a[j] = NSNumber(value: id) }
                let r = try await lm.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.name: MLFeatureValue(multiArray: a)]))
                let e = try Self.firstEmbedding(r, lm.model)
                out[i] = e
                await cache.set(t, e)
            }
            await cache.save()
        }
        return out.map { $0 ?? [] }
    }

    /// Each kind's probability, most likely first.
    public func classify(_ image: Bitmap) async throws -> [(kind: String, probability: Double)] {
        try await classify(embedding: imageEmbedding(image))
    }

    /// `.crop` is CLIP's own preprocessing (shorter side to the input, then the centre); `.pad` fits the whole
    /// picture in, on its own edge colour, so a spine or a banner keeps its shape.
    static func fitted(_ image: Bitmap, side: Int, fit: Fit) -> Bitmap {
        let flat = image.flattened()
        switch fit {
        case .crop:
            let k = Double(side) / Double(min(image.width, image.height))
            let w = max(side, Int((Double(image.width) * k).rounded())), h = max(side, Int((Double(image.height) * k).rounded()))
            return flat.resized(width: w, height: h).cropped(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        case .pad:
            let k = Double(side) / Double(max(image.width, image.height))
            let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
            let i = flat.index(0, 0)
            var out = Bitmap(width: side, height: side, fill: (flat.pixels[i], flat.pixels[i + 1], flat.pixels[i + 2], 255))
            flat.resized(width: w, height: h).composite(onto: &out, rect: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            return out
        }
    }

    /// The same, from an embedding already worked out.
    public func classify(embedding e: [Float]) async throws -> [(kind: String, probability: Double)] {
        let kinds = try await kindEmbeddings()
        let logits = kinds.map { 100 * Double(Self.dot(e, $0.1)) }
        let mx = logits.max() ?? 0
        let ex = logits.map { exp($0 - mx) }
        let sum = ex.reduce(0, +)
        return zip(kinds, ex).map { (kind: $0.0.0, probability: $0.1 / sum) }.sorted { $0.probability > $1.probability }
    }

    /// Each kind's averaged, re-normalised prompt embedding.
    func kindEmbeddings() async throws -> [(String, [Float])] {
        var result: [(String, [Float])] = []
        for (kind, prompts) in KindPrompts.byKind {
            let es = try await textEmbeddings(prompts)
            var mean = [Float](repeating: 0, count: es[0].count)
            for e in es { for i in mean.indices { mean[i] += e[i] } }
            result.append((kind, Self.normalised(mean)))
        }
        return result
    }

    static func firstEmbedding(_ out: MLFeatureProvider, _ m: MLModel) throws -> [Float] {
        let name = m.modelDescription.outputDescriptionsByName.values.first { $0.type == .multiArray }?.name
        guard let name, let a = out.featureValue(for: name)?.multiArrayValue else { throw IconLabError.tool("no embedding from \(m)") }
        return normalised(ModelIO.floats(a))
    }

    public static func normalised(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
}

/// Text embeddings by text, kept in a JSON file beside the model.
actor TextEmbeddingCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caches: [String: TextEmbeddingCache] = [:]
    static func shared(_ url: URL) -> TextEmbeddingCache {
        lock.lock(); defer { lock.unlock() }
        if let c = caches[url.path] { return c }
        let c = TextEmbeddingCache(url: url)
        caches[url.path] = c
        return c
    }

    let url: URL
    private var values: [String: [Float]]
    private var dirty = false

    init(url: URL) {
        self.url = url
        values = (try? JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: url))) ?? [:]
    }

    func get(_ t: String) -> [Float]? { values[t] }
    func set(_ t: String, _ e: [Float]) { values[t] = e; dirty = true }
    func save() {
        guard dirty else { return }
        do {
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
            dirty = false
        } catch {
            logger.warning("Couldn't keep the text embeddings at \(url.path): \(error)")
        }
    }
}

/// The tokenizer, read once.
actor TokenizerCache {
    static let shared = TokenizerCache()
    private var t: CLIPTokenizer?
    func tokenizer(_ folder: URL) throws -> CLIPTokenizer {
        if let t { return t }
        let n = try CLIPTokenizer(folder: folder)
        t = n
        return n
    }
}

nonisolated extension Array {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for e in self { out.append(try await f(e)) }
        return out
    }
}
