import CoreImage
import Foundation
import Vision

/// The deep tier: what's worth knowing about an image someone picked, once its largest copy is here.
/// Findings go in `MediaRecord.deep`; some make new, derived images (a photographed box straightened, borders
/// trimmed, the title cropped out) that are added to the program as media of their own.
nonisolated public enum Deep {
    public struct Derived: Sendable {
        public var bitmap: Bitmap
        public var name: String
        public var kind: String
        public var why: String
    }

    public struct Result: Sendable {
        public var findings: [String: JSONValue] = [:]
        public var derived: [Derived] = []
    }

    public static func analyse(_ image: Bitmap, cutout: Bitmap?, record: MediaRecord, programTitle: String) -> Result {
        var r = Result()
        guard let cg = image.flattened().cgImage else { return r }
        let handler = VNImageRequestHandler(cgImage: cg)

        // Aesthetics (macOS 15): how good a photo/picture it is, and whether it's a "utility" image (a scan, a
        // screenshot of text) that's unlikely to make an icon.
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let rects = VNDetectRectanglesRequest()
        rects.maximumObservations = 3
        rects.minimumSize = 0.35
        rects.minimumConfidence = 0.6
        rects.quadratureTolerance = 25
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        try? handler.perform([aesthetics, faces, rects, text])

        if let a = aesthetics.results?.first {
            r.findings["aesthetics"] = .number((Double(a.overallScore) * 100).rounded() / 100)
            r.findings["utility"] = .bool(a.isUtility)
        }
        let faceBoxes = (faces.results ?? []).map { box($0.boundingBox) }
        r.findings["faces"] = .number(Double(faceBoxes.count))
        if !faceBoxes.isEmpty { r.findings["faceBoxes"] = .array(faceBoxes.map { JSONValue.array($0.map { .number($0) }) }) }

        // A photographed box or a scan at an angle: straighten it.
        if let q = rects.results?.first, ["box-front", "box-back", "manual", "art", "other"].contains(record.kind) {
            let skew = quadSkew(q)
            r.findings["rectangle"] = .array([q.topLeft, q.topRight, q.bottomRight, q.bottomLeft].map { .array([.number(Double($0.x)), .number(Double(1 - $0.y))]) })
            if skew > 0.02, let straight = perspectiveCorrect(cg, q) {
                r.derived.append(Derived(bitmap: straight, name: "\(stem(record.name)) (straightened)", kind: record.kind,
                                         why: "Straightened from a photo at an angle"))
            }
        }

        // Plain borders and scan margins.
        if let t = trimBox(image), t.w * t.h < Int(Double(image.width * image.height) * 0.92) {
            r.findings["trim"] = .array([t.x, t.y, t.w, t.h].map { .number(Double($0)) })
            r.derived.append(Derived(bitmap: image.cropped(x: t.x, y: t.y, width: t.w, height: t.h), name: "\(stem(record.name)) (trimmed)",
                                     kind: record.kind, why: "Plain border trimmed"))
        }

        // The title: OCR lines that match the program's name, cropped out as a logo.
        let words = Set(programTitle.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        var titleBox: CGRect?
        for o in text.results ?? [] {
            guard let s = o.topCandidates(1).first?.string.lowercased() else { continue }
            let sw = Set(s.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            if !words.isEmpty, Double(words.intersection(sw).count) / Double(words.count) >= 0.5 || (words.count == 1 && !words.isDisjoint(with: sw)) {
                titleBox = titleBox.map { $0.union(o.boundingBox) } ?? o.boundingBox
            }
        }
        if let tb = titleBox, record.kind != "logo" {
            let b = box(tb)
            r.findings["titleBox"] = .array(b.map { .number($0) })
            let pad = 0.03
            let x = Int(max(0, b[0] - pad) * Double(image.width)), y = Int(max(0, b[1] - pad) * Double(image.height))
            let w = Int(min(1, b[2] + pad * 2) * Double(image.width)), h = Int(min(1, b[3] + pad * 2) * Double(image.height))
            if w > 64, h > 16 {
                r.derived.append(Derived(bitmap: image.cropped(x: x, y: y, width: min(w, image.width - x), height: min(h, image.height - y)),
                                         name: "\(stem(record.name)) (title)", kind: "logo", why: "The title, found by reading the text"))
            }
        }

        // How well the cut-out reads small: the best single predictor of a good icon.
        if let c = cutout { r.findings["legibility"] = .number(legibility(c)) }

        // Colour roles.
        let roles = paletteRoles(image)
        r.findings["paletteRoles"] = .object(roles.mapValues { .string($0.hex) })
        if let bg = roles["background"], let accent = roles["accent"] {
            r.findings["accentContrast"] = .number((contrast(bg, accent) * 100).rounded() / 100)
        }
        return r
    }

    static func stem(_ n: String) -> String { (n as NSString).deletingPathExtension }

    /// Vision box (y up) → [x, y, w, h] top-left.
    static func box(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(1 - r.maxY), Double(r.width), Double(r.height)].map { ($0 * 1000).rounded() / 1000 }
    }

    static func quadSkew(_ q: VNRectangleObservation) -> Double {
        let dx = abs(q.topLeft.x - q.bottomLeft.x) + abs(q.topRight.x - q.bottomRight.x)
        let dy = abs(q.topLeft.y - q.topRight.y) + abs(q.bottomLeft.y - q.bottomRight.y)
        return Double(dx + dy)
    }

    static func perspectiveCorrect(_ cg: CGImage, _ q: VNRectangleObservation) -> Bitmap? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        func p(_ v: CGPoint) -> CIVector { CIVector(x: v.x * w, y: v.y * h) }
        let ci = CIImage(cgImage: cg).applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": p(q.topLeft), "inputTopRight": p(q.topRight), "inputBottomLeft": p(q.bottomLeft), "inputBottomRight": p(q.bottomRight),
        ])
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return Bitmap(cgImage: out)
    }

    /// The box inside plain borders (rows/columns close to the edge colour), or nil when there's no border.
    static func trimBox(_ b: Bitmap) -> (x: Int, y: Int, w: Int, h: Int)? {
        let f = b.flattened()
        let i0 = f.index(0, 0)
        let edge = RGB(f.pixels[i0], f.pixels[i0 + 1], f.pixels[i0 + 2])
        func plain(_ xs: Range<Int>, _ ys: Range<Int>) -> Bool {
            var off = 0, n = 0
            for y in ys { for x in xs {
                let i = f.index(x, y)
                let d = abs(Int(f.pixels[i]) - Int(edge.r)) + abs(Int(f.pixels[i + 1]) - Int(edge.g)) + abs(Int(f.pixels[i + 2]) - Int(edge.b))
                if d > 40 { off += 1 }
                n += 1
            } }
            return n > 0 && Double(off) / Double(n) < 0.02
        }
        var x0 = 0, x1 = f.width, y0 = 0, y1 = f.height
        while x0 < x1 - 8, plain(x0..<(x0 + 1), y0..<y1) { x0 += 1 }
        while x1 > x0 + 8, plain((x1 - 1)..<x1, y0..<y1) { x1 -= 1 }
        while y0 < y1 - 8, plain(x0..<x1, y0..<(y0 + 1)) { y0 += 1 }
        while y1 > y0 + 8, plain(x0..<x1, (y1 - 1)..<y1) { y1 -= 1 }
        if x0 == 0, y0 == 0, x1 == f.width, y1 == f.height { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// 0…1: how much of the cut-out's silhouette and inner contrast survives at 32 and 16 px.
    public static func legibility(_ cutout: Bitmap) -> Double {
        func stats(_ n: Int) -> (fill: Double, contrast: Double) {
            let k = Double(n) / Double(max(cutout.width, cutout.height))
            let s = cutout.resized(width: max(1, Int(Double(cutout.width) * k)), height: max(1, Int(Double(cutout.height) * k)))
            var on = 0.0, total = 0.0, lum: [Double] = []
            for i in stride(from: 0, to: s.pixels.count, by: 4) {
                total += 1
                if s.pixels[i + 3] > 127 { on += 1; lum.append(s.luma(i)) }
            }
            let m = lum.reduce(0, +) / Double(max(1, lum.count))
            let sd = sqrt(lum.reduce(0) { $0 + pow($1 - m, 2) } / Double(max(1, lum.count)))
            return (on / max(1, total), sd / 128)
        }
        let big = stats(256), s32 = stats(32), s16 = stats(16)
        let keep32 = min(1, s32.contrast / max(0.01, big.contrast)), keep16 = min(1, s16.contrast / max(0.01, big.contrast))
        let fill = min(1, s16.fill / 0.35)   // a silhouette that fills a fair share of its box reads better
        return ((0.45 * keep32 + 0.3 * keep16 + 0.25 * fill) * 100).rounded() / 100
    }

    /// Accent (striking, small share), background (the border's colour), ink (darkest), paper (lightest).
    public static func paletteRoles(_ b: Bitmap) -> [String: RGB] {
        let cs = Palette.clusters(b, k: 8)
        guard let dominant = cs.first?.colour else { return [:] }
        var border = (0.0, 0.0, 0.0), n = 0.0
        for x in stride(from: 0, to: b.width, by: max(1, b.width / 64)) {
            for y in [0, b.height - 1] { let i = b.index(x, y); border.0 += Double(b.pixels[i]); border.1 += Double(b.pixels[i + 1]); border.2 += Double(b.pixels[i + 2]); n += 1 }
        }
        let accent = cs.filter { $0.share < 0.25 }.max { $0.colour.chroma < $1.colour.chroma }?.colour ?? dominant
        let byL = cs.sorted { $0.colour.lab.l < $1.colour.lab.l }
        return ["dominant": dominant, "accent": accent, "background": RGB(r: border.0 / n, g: border.1 / n, b: border.2 / n),
                "ink": byL.first?.colour ?? dominant, "paper": byL.last?.colour ?? dominant]
    }

    /// WCAG contrast ratio.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        func l(_ c: RGB) -> Double {
            func ch(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
        }
        let (x, y) = (l(a), l(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// Downloads for picked images. archive.org gets one request every 4 s, sequentially (the limit it asks of
/// scrapers); other hosts one at a time with a short gap.
public actor Downloader {
    private var lastByHost: [String: Date] = [:]
    public init() {}

    public func data(_ url: URL, maxBytes: Int = 60_000_000) async throws -> Data {
        let host = url.host ?? ""
        let gap: TimeInterval = host.hasSuffix("archive.org") ? 4 : 0.5
        if let last = lastByHost[host] {
            let wait = gap - Date().timeIntervalSince(last)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lastByHost[host] = Date()
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("SecondChanceIconLab/0.1 (local tool)", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: req)
        lastByHost[host] = Date()
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw IconLabError.tool("HTTP \(h.statusCode) for \(url)") }
        guard d.count <= maxBytes else { throw IconLabError.tool("\(url.lastPathComponent) is too big (\(d.count) bytes)") }
        return d
    }
}
