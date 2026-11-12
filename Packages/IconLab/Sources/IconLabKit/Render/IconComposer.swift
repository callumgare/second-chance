import Foundation
import Logging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Render")

/// Writes a document as an Icon Composer `.icon` and renders it with `ictool` (the real Liquid Glass).
nonisolated public struct IconComposer: Sendable {
    public let renderer: Renderer
    public let cacheDir: URL
    /// Part of every cache key: bump when rendering changes what it makes.
    public static let revision = "r5"

    /// Icon Composer's renderer, if this Mac has it (`LabTools.ictool`).
    public let ictool: String?

    public init(renderer: Renderer, cacheDir: URL, ictool: String?) {
        self.renderer = renderer
        self.cacheDir = cacheDir
        self.ictool = ictool
    }

    /// A stable hash of what a document looks like (not its id, name or history).
    public static func visualKey(_ doc: Doc) -> String {
        struct Visual: Encodable { let program: String; let fill: Fill; let groups: [Group]; let rev: String }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = (try? e.encode(Visual(program: doc.program, fill: doc.fill, groups: doc.groups, rev: revision))) ?? Data()
        return String(Store.sha256(data).prefix(20))
    }

    /// Writes `<cache>/icons/<key>.icon` (if it isn't there) and returns it.
    public func write(_ doc: Doc) async throws -> URL {
        let key = IconComposer.visualKey(doc)
        let dir = cacheDir.appendingPathComponent("icons").appendingPathComponent("\(key).icon")
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("icon.json").path) { return dir }
        let tmp = cacheDir.appendingPathComponent("icons").appendingPathComponent("\(key)-\(UUID().uuidString).tmp.icon")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        var groups: [[String: Any]] = []
        for g in doc.groups where g.hidden != true {
            var layers: [[String: Any]] = []
            for l in g.layers where l.hidden != true {
                let bmp = try await renderer.layer(l, program: doc.program, size: 1024)
                let name = Store.slugify(l.id)
                try bmp.writePNG(to: tmp.appendingPathComponent("Assets").appendingPathComponent("\(name).png"))
                layers.append(["image-name": "\(name).png", "name": name])
            }
            if layers.isEmpty { continue }
            var group: [String: Any] = [
                "layers": layers, "lighting": g.glass.lighting == "combined" ? "combined" : "individual", "specular": g.glass.specular,
                "shadow": ["kind": ["none": "none", "chromatic": "layer-color"][g.glass.shadowKindResolved] ?? "neutral",
                           "opacity": g.glass.shadow],
                "translucency": ["enabled": g.glass.translucency != nil, "value": g.glass.translucency ?? 0.5],
            ]
            if let b = g.glass.blur { group["blur-material"] = b }
            groups.append(group)
        }
        var json: [String: Any] = ["groups": groups, "supported-platforms": ["squares": "shared"]]
        if doc.fill.kind != .none {
            let kind = doc.fill.kind == .gradient ? "automatic-gradient" : "solid"
            let dark = doc.fill.dark ?? doc.fill.color.shade(0.45)
            json["fill-specializations"] = [["value": [kind: doc.fill.color.iconComposer]],
                                            ["appearance": "dark", "value": [kind: dark.iconComposer]]]
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: tmp.appendingPathComponent("icon.json"))
        if FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.moveItem(at: tmp, to: dir)
        return dir
    }

    public static let renditions = ["light": "Default", "dark": "Dark", "tinted": "TintedLight", "clear": "ClearLight"]

    /// The rendered PNG for an appearance and size (cached).
    /// The rendered PNG if it's already been made, without making it.
    public func cached(_ doc: Doc, appearance: String, size: Int) -> URL? {
        let key = IconComposer.visualKey(doc)
        let png = cacheDir.appendingPathComponent("icons").appendingPathComponent("\(key).\(appearance)-\(max(16, min(1024, size))).png")
        return FileManager.default.fileExists(atPath: png.path) ? png : nil
    }

    public func render(_ doc: Doc, appearance: String, size: Int) async throws -> (png: URL, icon: URL) {
        let icon = try await write(doc)
        let size = max(16, min(1024, size))
        let png = icon.deletingPathExtension().appendingPathExtension("\(appearance)-\(size).png")
        if FileManager.default.fileExists(atPath: png.path) { return (png, icon) }
        guard let tool = ictool else { throw IconLabError.tool("ictool isn't installed (Xcode 26's Icon Composer)") }
        let rendition = IconComposer.renditions[appearance] ?? "Default"
        let out = try await Run.tool(tool, [icon.path, "--export-image", "--output-file", png.path, "--platform", "macOS",
                                            "--rendition", rendition, "--width", "\(size)", "--height", "\(size)", "--scale", "1"],
                                     timeout: 90)
        guard FileManager.default.fileExists(atPath: png.path) else {
            throw IconLabError.tool("ictool made no picture: \(out.suffix(400))")
        }
        return (png, icon)
    }
}

/// Runs a program and returns its output (stdout, then stderr), off the calling task's thread.
nonisolated public enum Run {
    /// Stopped after `timeout` seconds; what it said by then is still returned, as the caller checks what it made.
    public static func tool(_ path: String, _ args: [String], timeout: TimeInterval = 120) async throws -> String {
        do {
            let r = try await withTimeout(timeout) { try await Process.output(of: path, args) }
            if !r.succeeded { logger.warning("\((path as NSString).lastPathComponent) exited \(r.status)") }
            return r.output + r.errorOutput
        } catch is TimeoutError {
            logger.error("\((path as NSString).lastPathComponent) was stopped after \(Int(timeout)) s")
            return ""
        }
    }
}
