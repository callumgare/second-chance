import Foundation

/// One image of a program, with what we know about it (api.md's `Media`, less the URLs the server adds).
nonisolated public struct MediaRecord: Codable, Sendable {
    public var id: String
    public var name: String
    public var file: String                 // file name under media/
    public var kind: String
    public var kindConfidence: Double
    public var kindSet: Bool?               // the person corrected the kind: analysis leaves it alone
    public var source: String
    public var sourceUrl: String?
    public var provenance: String?
    public var width: Int
    public var height: Int
    public var picked: Bool
    public var hasMask: Bool
    public var analysis: MediaAnalysis
    /// What analysis last measured. What ranks pictures is `Lab.suitability`, worked out afresh from the record.
    public var suitability: Double
    public var added: String
    /// Where it came from online (stage 2's sources): the full-size URL and what the source said about it. The file
    /// in media/ may be a small copy until a hi-res download replaces it.
    public var remote: RemoteMedia?
    /// The hi-res download and deep analysis for a picked image: nil (not asked), queued, running, done, failed.
    public var hires: String?
    /// The hi-res look found and downloaded a larger copy (the picture's file was replaced).
    public var upgraded: Bool?
    /// You hid it: out of the grid (unless "Show hidden") and out of the suggestions.
    public var hidden: Bool?
    /// How likely it's about the program (0…1) and why: for pictures a general search found (Relevance).
    public var relevance: Double?
    public var relevanceWhy: [String]?
    /// Same art as another image (perceptual match): that image's id. The UI folds duplicates under the best copy.
    public var duplicateOf: String?
    /// Made from another image by the deep analysis (straightened, trimmed, its title): that image's id.
    public var derivedFrom: String?
    /// The cut-out's size in pixels (its crop of the image), once there's a mask.
    public var cutoutSize: [Int]?
    /// The deep tier's findings (on picked images).
    public var deep: [String: JSONValue]?
    /// Where the kind came from: "you", "source" (an exact label match) or "analysis" (MobileCLIP, when sure).
    public var kindSource: String?
    /// MobileCLIP's best guesses, for the inspector.
    public var kindGuesses: [KindGuess]?
    /// What the source called it ("Cart - Front").
    public var sourceLabel: String?
    /// The picture's own turn, clockwise (the whole part's), and whether and why it was chosen automatically.
    public var rotation: Int?
    public var rotationAuto: Bool?
    public var rotationWhy: String?
    /// The picture's parts: the whole picture first, then what was cut or cropped out of it.
    public var parts: [Part]?

    public init(id: String, name: String, file: String, kind: String = "other", kindConfidence: Double = 0,
                source: String, sourceUrl: String? = nil, provenance: String? = nil, width: Int, height: Int,
                picked: Bool = false, hasMask: Bool = false, analysis: MediaAnalysis = .init(), suitability: Double = 0) {
        self.id = id; self.name = name; self.file = file; self.kind = kind; self.kindConfidence = kindConfidence
        self.source = source; self.sourceUrl = sourceUrl; self.provenance = provenance
        self.width = width; self.height = height; self.picked = picked; self.hasMask = hasMask
        self.analysis = analysis; self.suitability = suitability
        added = ISO8601DateFormatter().string(from: Date())
    }
}

nonisolated public struct MediaAnalysis: Codable, Sendable {
    public var subject = false
    public var subjectBox: [Double]?        // x, y, w, h in 0…1
    public var flatSides: [String] = []
    public var text: [String] = []
    public var textFraction = 0.0
    public var busyness = 0.0
    public var palette: [String] = []
    public var circle: [Double]?            // centre x, y, radius (radius as a share of the shorter side)
    public var pixelArt: Bool?
    /// Some of it is see-through (a cut-out logo, an icon): usable as a silhouette as it is.
    public var hasAlpha: Bool?
    public var coverage = 0.0               // the subject's share of the picture
    public var solidity = 0.0               // the subject's area against its box
    public var colours = 0                  // distinct colours (coarse)
    public var entropy = 0.0
    public var colourfulness = 0.0
    public var scores: [String: Double] = [:]
    public var version = 0                  // analysis revision that produced this
    public init() {}
}

nonisolated public enum MediaKind {
    public static let all = ["box-front", "box-back", "box-spine", "disc", "media", "logo", "icon", "title-screen", "screenshot",
                             "banner", "manual", "cutout", "art", "other"]

    /// The first lab's kinds, mapped.
    public static func fromV1(_ k: String) -> String {
        ["cover": "box-front", "title": "title-screen", "screenshot": "screenshot", "disc": "disc", "logo": "logo",
         "icon": "icon", "art": "art", "other": "other"][k] ?? "other"
    }
}

nonisolated public struct KindGuess: Codable, Sendable { public var kind: String; public var p: Double }

/// A part of a picture: the whole of it, or something cut or cropped out of it (docs/api.md "Parts").
nonisolated public struct Part: Codable, Sendable {
    public var id: String
    public var name: String
    public var source: String            // whole | subject | instance | text | rectangle | disc | region | sam
    public var kind: String
    public var kindSet: Bool?
    public var box: [Double]             // x, y, w, h in the unturned picture, 0…1
    public var quad: [[Double]]?         // TL, TR, BR, BL, 0…1: straightened when it's made
    public var hasMask: Bool
    public var rotation: Int
    public var rotationAuto: Bool?
    public var rotationWhy: String?
    public var picked: Bool
    public var size: [Int]?
    public var flatSides: [String]?
    public var circle: [Double]?         // a disc's circle in the part's own picture
    public var edges: Edges?
    public var prompt: JSONValue?
    public var auto: Bool?               // found by analysis (replaced when it runs again), not made by you
    /// A part with a picture of its own (a video's other frames), in media/: shown instead of a crop of the whole.
    public var file: String?
    /// For a cut-out from a video's frame other than the best one: that frame's part id (its picture is the base).
    public var frame: String?

    public init(id: String, name: String, source: String, kind: String = "unknown", box: [Double] = [0, 0, 1, 1],
                hasMask: Bool = false, rotation: Int = 0, picked: Bool = false, auto: Bool = true) {
        self.id = id; self.name = name; self.source = source; self.kind = kind; self.box = box
        self.hasMask = hasMask; self.rotation = rotation; self.picked = picked; self.auto = auto
    }
}

nonisolated public struct Edges: Codable, Sendable, Hashable {
    public var grow: Double = 0          // px at the picture's size (negative shrinks)
    public var soften: Double = 0        // px
    public var fillHoles: Bool = false
    public init() {}
}

nonisolated extension MediaRecord {
    /// The parts, always with the whole picture first.
    public var allParts: [Part] {
        var ps = parts ?? []
        if !ps.contains(where: { $0.id == "whole" }) {
            var w = Part(id: "whole", name: "Whole picture", source: "whole", kind: kind, rotation: rotation ?? 0, picked: picked && (parts ?? []).isEmpty)
            w.size = [width, height]
            ps.insert(w, at: 0)
        }
        return ps
    }

    /// Picked when any part is.
    public var anyPicked: Bool { allParts.contains(where: \.picked) }
}
