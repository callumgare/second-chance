import Foundation

/// What Icon Lab uses from outside itself, which the host finds and passes in: the programs it runs and the places
/// it offers in the file browser. Any of them may be missing; what needs it then says so.
nonisolated public struct LabTools: Sendable {
    /// Xcode's Icon Composer renderer, for Final renders.
    public var ictool: String?
    /// Where built wrapps are (a checkout's `built-apps/`): a place in the file browser, the wrapps "Add from files"
    /// lists, and where "Try on a wrapp" may change an app without asking.
    public var builtApps: URL?

    public init(ictool: String? = nil, builtApps: URL? = nil) {
        self.ictool = ictool
        self.builtApps = builtApps
    }

    /// Where Xcode keeps Icon Composer's renderer.
    public static let xcodeICTool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

    /// Xcode's `ictool` if it's installed.
    public static var installedICTool: String? {
        FileManager.default.isExecutableFile(atPath: xcodeICTool) ? xcodeICTool : nil
    }

    /// The tools as a checkout has them: Xcode's `ictool` if it's installed, and the checkout's `built-apps/`.
    public static func inCheckout(_ checkout: URL) -> LabTools {
        LabTools(ictool: installedICTool, builtApps: checkout.appendingPathComponent("built-apps"))
    }
}

/// What the host knows that Icon Lab doesn't: the programs it has bundles for, and where those bundles are when they
/// can be written to. Second Chance passes its own; the dev server whatever it's told.
nonisolated public struct LabHostInfo: Sendable {
    /// The programs the host has bundles for, listed first when finding a program.
    public var knownPrograms: [KnownProgram]
    /// A checkout's `Bundles/` folder, which "Save to the bundle" writes into; nil leaves it unavailable.
    public var bundles: URL?

    public init(knownPrograms: [KnownProgram] = [], bundles: URL? = nil) {
        self.knownPrograms = knownPrograms
        self.bundles = bundles
    }
}

/// A program the host has a bundle for.
nonisolated public struct KnownProgram: Codable, Sendable, Hashable {
    /// The bundle id: `nancy-drew/old-clock`, `freeware/skifree`.
    public var id: String
    public var title: String
    public var year: Int?
    public var platforms: [String]
    public var developer: String?
    public var publisher: String?

    public init(id: String, title: String, year: Int? = nil, platforms: [String] = [], developer: String? = nil, publisher: String? = nil) {
        self.id = id
        self.title = title
        self.year = year
        self.platforms = platforms
        self.developer = developer
        self.publisher = publisher
    }

    /// The Icon Lab program's slug for a bundle id: safe as a folder's name (`nancy-drew--old-clock`).
    public static func slug(forBundle id: String) -> String {
        id.split(separator: "/").map { Store.slugify(String($0)) }.filter { !$0.isEmpty }.joined(separator: "--")
    }

    /// Reads a `Bundles/` folder's manifests as far as their ids and titles (`id:` and `title:` lines), for a host
    /// with no bundle loader of its own.
    public static func read(bundles root: URL) -> [KnownProgram] {
        let fm = FileManager.default
        var out: [KnownProgram] = []
        for group in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            for name in ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(group).path)) ?? []).sorted() {
                let manifest = root.appendingPathComponent(group).appendingPathComponent(name).appendingPathComponent("manifest.yaml")
                guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
                func field(_ key: String) -> String? {
                    for line in text.split(separator: "\n") where line.hasPrefix("\(key):") {
                        var v = line.dropFirst(key.count + 1)
                        if let hash = v.range(of: " #") { v = v[..<hash.lowerBound] }
                        return v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                    return nil
                }
                guard let id = field("id") else { continue }
                out.append(KnownProgram(id: id, title: field("display-name") ?? field("title") ?? name))
            }
        }
        return out
    }
}
