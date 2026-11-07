import Accelerate
import CoreML
import CryptoKit
import Foundation

/// Click-to-segment with SAM 2.1 (small), Apple's Core ML conversion: an image encoder run once per picture, then
/// a prompt encoder and a mask decoder per click (milliseconds). As Apple's SAM2-Studio sample does it: the picture
/// is stretched to 1024 × 1024 (normalisation is inside the model); a point at (x, y) in 0…1 of the picture is
/// (x × 1024, y × 1024); labels are 1 for "this", 0 for "not this", and 2 / 3 for a box's top-left and bottom-right
/// corners (box first, as SAM 2's predictor orders them); the decoder gives three 256 × 256 masks as logits
/// (stretched like the input) with a predicted IoU score each, upsampled to the picture and thresholded at 0.
nonisolated public enum Segmenter {
    public static let imageEncoder = "sam2.1-small-image-encoder"
    public static let promptEncoder = "sam2.1-small-prompt-encoder"
    public static let maskDecoder = "sam2.1-small-mask-decoder"
    public static let modelNames = [imageEncoder, promptEncoder, maskDecoder]
    static let side = 1024.0

    public struct Point: Sendable, Equatable {
        public var x: Double, y: Double
        public var positive: Bool
        public init(x: Double, y: Double, positive: Bool) { self.x = x; self.y = y; self.positive = positive }
    }

    /// One of the three answers to a click.
    public struct Mask: Sendable {
        public var mask: Bitmap          // grey (white = the part), the picture's size, edges anti-aliased
        public var score: Double         // the model's own estimate of its IoU, 0…1
        public var area: Double          // the part's share of the picture
        public var sizeRank: Int         // 0 = smallest of the three ("a part"), 1 ("part"), 2 = largest ("whole")
    }

    /// The prompt in the model's coordinates: box corners first (labels 2, 3), then points (1 or 0). `region` is
    /// [x, y, w, h] in 0…1. Coordinates outside the picture are clamped to it.
    public static func prompt(points: [Point], region: [Double]?) -> [(x: Float, y: Float, label: Float)] {
        func c(_ v: Double) -> Float { Float(min(max(v, 0), 1) * side) }
        var out: [(x: Float, y: Float, label: Float)] = []
        if let r = region, r.count == 4 {
            out.append((c(r[0]), c(r[1]), 2))
            out.append((c(r[0] + r[2]), c(r[1] + r[3]), 3))
        }
        for p in points { out.append((c(p.x), c(p.y), p.positive ? 1 : 0)) }
        return out
    }
}

nonisolated extension Models {
    /// The three masks SAM gives for clicks (and/or a box) on a picture, best score first. `key` names the picture
    /// as it is now (e.g. "<slug>/<media id>@<file stamp>"): its encoding is kept in memory (the last few) and in
    /// data/cache/sam/, so later clicks on it only run the decoder.
    public func segment(_ image: Bitmap, key: String, points: [Segmenter.Point], region: [Double]? = nil) async throws -> [Segmenter.Mask] {
        let prompt = Segmenter.prompt(points: points, region: region)
        guard !prompt.isEmpty else { throw IconLabError.invalid("segmenting needs a point or a region") }
        let enc = try await samEncoding(image, key: key)
        let pe = try await store.model(Segmenter.promptEncoder, jobs: jobs).model
        let md = try await store.model(Segmenter.maskDecoder, jobs: jobs).model

        // prompt encoder
        let ptType = pe.modelDescription.inputDescriptionsByName["points"]?.multiArrayConstraint?.dataType ?? .float16
        let lbType = pe.modelDescription.inputDescriptionsByName["labels"]?.multiArrayConstraint?.dataType ?? .float16
        let pts = try MLMultiArray(shape: [1, NSNumber(value: prompt.count), 2], dataType: ptType)
        let lbs = try MLMultiArray(shape: [1, NSNumber(value: prompt.count)], dataType: lbType)
        for (i, p) in prompt.enumerated() {
            pts[[0, i, 0] as [NSNumber]] = NSNumber(value: p.x)
            pts[[0, i, 1] as [NSNumber]] = NSNumber(value: p.y)
            lbs[[0, i] as [NSNumber]] = NSNumber(value: p.label)
        }
        let po = try await pe.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": pts, "labels": lbs]))
        guard let sparse = po.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = po.featureValue(for: "dense_embeddings")?.multiArrayValue else { throw IconLabError.tool("no prompt embeddings from SAM") }

        // mask decoder
        let out = try await md.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": try enc.array(0), "feats_s0": try enc.array(1), "feats_s1": try enc.array(2),
            "sparse_embedding": sparse, "dense_embedding": dense,
        ]))
        guard let low = out.featureValue(for: "low_res_masks")?.multiArrayValue,
              let sc = out.featureValue(for: "scores")?.multiArrayValue else { throw IconLabError.tool("no masks from SAM") }
        let logits = ModelIO.floats(low), scores = ModelIO.floats(sc)
        let n = low.shape.count == 4 ? low.shape[1].intValue : 1
        guard low.shape.count >= 2 else { throw IconLabError.tool("SAM's masks have shape \(low.shape)") }
        let h = low.shape[low.shape.count - 2].intValue, w = low.shape[low.shape.count - 1].intValue

        var masks: [Segmenter.Mask] = []
        for k in 0..<n {
            // SAM's half-precision output carries a fine grid of noise where it's unsure: smooth it a little at its
            // own resolution, before upsampling, so the edge follows the shape rather than the grid
            let plane = Segmenter.smooth(Array(logits[(k * w * h)..<((k + 1) * w * h)]), width: w, height: h, passes: 2)
            let area = Double(plane.filter { $0 > 0 }.count) / Double(w * h)
            let big = Segmenter.upsample(plane, width: w, height: h, toWidth: image.width, toHeight: image.height)
            masks.append(Segmenter.Mask(mask: Segmenter.maskBitmap(big, width: image.width, height: image.height),
                                        score: Double(scores[k]), area: area, sizeRank: 0))
        }
        let bySize = masks.indices.sorted { masks[$0].area < masks[$1].area }
        for (rank, i) in bySize.enumerated() { masks[i].sizeRank = rank }
        return masks.sorted { $0.score > $1.score }
    }

    /// The same, with points as tuples.
    public func segment(_ image: Bitmap, key: String, points: [(x: Double, y: Double, positive: Bool)],
                        region: [Double]? = nil) async throws -> [Segmenter.Mask] {
        try await segment(image, key: key, points: points.map { Segmenter.Point(x: $0.x, y: $0.y, positive: $0.positive) }, region: region)
    }

    /// Encodes the picture now (e.g. when it's opened in the editor), so the first click is quick.
    public func prepareSegmenting(_ image: Bitmap, key: String) async throws {
        _ = try await samEncoding(image, key: key)
    }

    func samEncoding(_ image: Bitmap, key: String) async throws -> SAMEncoding {
        let cache = SAMCache.shared(store.root.deletingLastPathComponent().appendingPathComponent("cache/sam"))
        if let e = await cache.get(key) { return e }
        let ie = try await store.model(Segmenter.imageEncoder, jobs: jobs).model
        let pb = try ModelIO.pixelBuffer(image.flattened().resized(width: Int(Segmenter.side), height: Int(Segmenter.side)))
        let out = try await ie.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)]))
        var parts: [SAMEncoding.Part] = []
        for name in ["image_embedding", "feats_s0", "feats_s1"] {
            guard let a = out.featureValue(for: name)?.multiArrayValue else { throw IconLabError.tool("SAM's encoder gave no \(name)") }
            parts.append(SAMEncoding.Part(a))
        }
        let e = SAMEncoding(parts: parts)
        await cache.put(key, e)
        return e
    }
}

/// The image encoder's three outputs, as plain bytes (Sendable, and what goes to disk).
nonisolated struct SAMEncoding: Sendable {
    struct Part: Sendable {
        var shape: [Int]
        var type: Int          // MLMultiArrayDataType's raw value
        var bytes: Data

        init(shape: [Int], type: Int, bytes: Data) { self.shape = shape; self.type = type; self.bytes = bytes }

        /// Copies the array's elements in order (Core ML's outputs may have padded strides).
        init(_ a: MLMultiArray) {
            shape = a.shape.map(\.intValue)
            if a.dataType == .float16 {
                type = Int(MLMultiArrayDataType.float16.rawValue)
                var out = Data(count: a.count * 2)
                let contiguous = a.strides.map(\.intValue) == Part.strides(shape)
                out.withUnsafeMutableBytes { dst in
                    let d = dst.bindMemory(to: UInt16.self)
                    if contiguous {
                        let s = a.dataPointer.assumingMemoryBound(to: UInt16.self)
                        for i in 0..<a.count { d[i] = s[i] }
                    } else {
                        for i in 0..<a.count { d[i] = HalfFloat.bits(a[i].floatValue) }
                    }
                }
                bytes = out
            } else {
                type = Int(MLMultiArrayDataType.float32.rawValue)
                var out = Data(count: a.count * 4)
                out.withUnsafeMutableBytes { dst in
                    let d = dst.bindMemory(to: Float.self)
                    for i in 0..<a.count { d[i] = a[i].floatValue }
                }
                bytes = out
            }
        }

        static func strides(_ shape: [Int]) -> [Int] {
            var s = [Int](repeating: 1, count: shape.count)
            for i in stride(from: shape.count - 2, through: 0, by: -1) { s[i] = s[i + 1] * shape[i + 1] }
            return s
        }
    }

    var parts: [Part]

    func array(_ i: Int) throws -> MLMultiArray {
        let p = parts[i]
        let type = MLMultiArrayDataType(rawValue: p.type) ?? .float16
        let a = try MLMultiArray(shape: p.shape.map { NSNumber(value: $0) }, dataType: type)
        p.bytes.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }   // no bytes: nothing to copy
            a.dataPointer.copyMemory(from: base, byteCount: min(src.count, a.count * (type == .float16 ? 2 : 4)))
        }
        return a
    }

    // On disk: "SAM1", part count, then per part: rank, shape, type, byte count, bytes (all Int32 little-endian).
    func encoded() -> Data {
        var d = Data("SAM1".utf8)
        func i32(_ v: Int) { var x = Int32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        i32(parts.count)
        for p in parts {
            i32(p.shape.count); p.shape.forEach(i32); i32(p.type); i32(p.bytes.count); d.append(p.bytes)
        }
        return d
    }

    init(parts: [Part]) { self.parts = parts }

    init?(_ d: Data) {
        guard d.count > 8, d.prefix(4) == Data("SAM1".utf8) else { return nil }
        var o = 4
        func i32() -> Int? {
            guard o + 4 <= d.count else { return nil }
            let v = d.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            o += 4
            return Int(Int32(littleEndian: v))
        }
        guard let n = i32(), n == 3 else { return nil }
        var ps: [Part] = []
        for _ in 0..<n {
            guard let r = i32(), r > 0, r < 8 else { return nil }
            var shape: [Int] = []
            for _ in 0..<r { guard let s = i32() else { return nil }; shape.append(s) }
            guard let t = i32(), let c = i32(), o + c <= d.count else { return nil }
            ps.append(Part(shape: shape, type: t, bytes: d.subdata(in: o..<(o + c))))
            o += c
        }
        parts = ps
    }
}

/// Encodings by key: the last few in memory, all on disk (8 MB each) until the cache is cleared.
actor SAMCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caches: [String: SAMCache] = [:]
    static func shared(_ dir: URL) -> SAMCache {
        lock.lock(); defer { lock.unlock() }
        if let c = caches[dir.path] { return c }
        let c = SAMCache(dir: dir)
        caches[dir.path] = c
        return c
    }

    let dir: URL
    let capacity = 6
    private var recent: [(String, SAMEncoding)] = []

    init(dir: URL) { self.dir = dir }

    func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data("\(Segmenter.imageEncoder)|\(key)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(h).sam")
    }

    func get(_ key: String) -> SAMEncoding? {
        if let i = recent.firstIndex(where: { $0.0 == key }) {
            let e = recent.remove(at: i)
            recent.append(e)
            return e.1
        }
        guard let d = try? Data(contentsOf: file(key)), let e = SAMEncoding(d) else { return nil }
        remember(key, e)
        return e
    }

    func put(_ key: String, _ e: SAMEncoding) {
        remember(key, e)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try e.encoded().write(to: file(key), options: .atomic)
        } catch {
            // the memory copy still serves; next process encodes again
        }
    }

    private func remember(_ key: String, _ e: SAMEncoding) {
        recent.removeAll { $0.0 == key }
        recent.append((key, e))
        if recent.count > capacity { recent.removeFirst() }
    }
}

nonisolated extension Segmenter {
    /// Bilinear upsampling of a logit field (vImage), so the threshold falls between pixels smoothly.
    static func upsample(_ src: [Float], width w: Int, height h: Int, toWidth fullW: Int, toHeight fullH: Int) -> [Float] {
        var input = src
        var out = [Float](repeating: 0, count: fullW * fullH)
        input.withUnsafeMutableBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                var s = vImage_Buffer(data: ip.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: op.baseAddress, height: vImagePixelCount(fullH), width: vImagePixelCount(fullW), rowBytes: fullW * 4)
                _ = vImageScale_PlanarF(&s, &d, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    /// A 3×3 box blur, `passes` times (≈ a small Gaussian).
    static func smooth(_ src: [Float], width w: Int, height h: Int, passes: Int) -> [Float] {
        var a = src, b = src
        for _ in 0..<passes {
            for y in 0..<h { for x in 0..<w {
                var sum: Float = 0, n: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < w, yy < h { sum += a[yy * w + xx]; n += 1 }
                } }
                b[y * w + x] = sum / n
            } }
            swap(&a, &b)
        }
        return a
    }

    /// Logits → grey: 0 at logit −0.15 or less, 255 at +0.15 or more (so the edge is the 0 contour, anti-aliased).
    static func maskBitmap(_ logits: [Float], width: Int, height: Int) -> Bitmap {
        var b = Bitmap(width: width, height: height)
        b.pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<(width * height) {
                // a narrow band around the 0 contour: a smooth edge, but no see-through haze where SAM is unsure
                let v = UInt8(max(0, min(255, (logits[i] + 0.15) / 0.3 * 255)))
                p[i * 4] = v; p[i * 4 + 1] = v; p[i * 4 + 2] = v; p[i * 4 + 3] = 255
            }
        }
        return b
    }
}
