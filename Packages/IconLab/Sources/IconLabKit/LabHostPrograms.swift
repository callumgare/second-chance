import Foundation
import Logging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Host")

/// Icon Lab and the host's programs: the programs it has bundles for, the wrapps it has built, trying a design on
/// one of them, and saving the pinned designs to a program's bundle (docs/api.md, "The host's programs").
nonisolated extension Lab {
    // MARK: Known programs

    public struct KnownProgramDTO: Codable, Sendable {
        var id, title, slug: String
        var year: Int?
        var platforms: [String]
        var developer, publisher: String?
        /// Whether Icon Lab has a program for it yet.
        var opened: Bool
    }

    /// The host's programs, by title.
    public func knownPrograms() async -> [KnownProgramDTO] {
        var out: [KnownProgramDTO] = []
        for k in host.knownPrograms.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            let slug = KnownProgram.slug(forBundle: k.id)
            out.append(KnownProgramDTO(id: k.id, title: k.title, slug: slug, year: k.year, platforms: k.platforms,
                                       developer: k.developer, publisher: k.publisher, opened: await store.program(slug) != nil))
        }
        return out
    }

    /// The program for the host's program `id`, made if there isn't one yet; its slug, and whether it was made.
    public func openKnown(_ id: String) async throws -> (slug: String, created: Bool) {
        guard let k = host.knownPrograms.first(where: { $0.id == id }) else { throw IconLabError.notFound("program \(id)") }
        let slug = KnownProgram.slug(forBundle: k.id)
        guard !slug.isEmpty else { throw IconLabError.invalid("bundle id \(id)") }
        if var p = await store.program(slug) {
            if p.bundleId != k.id {
                p.bundleId = k.id
                try await store.saveProgram(p)
            }
            return (slug, false)
        }
        var p = Store.ProgramInfo(slug: slug, title: k.title, year: k.year, ids: nil, platforms: k.platforms.isEmpty ? nil : k.platforms)
        p.developer = k.developer
        p.publisher = k.publisher
        p.bundleId = k.id
        try await store.saveProgram(p)
        return (slug, true)
    }

    // MARK: Wrapps

    public struct WrappDTO: Codable, Sendable {
        var name, path: String
        var bundleIdentifier: String?
        var modified: String?
    }

    /// The wrapps in the host's built-apps folder, newest first.
    public func wrapps() -> [WrappDTO] {
        guard let folder = tools.builtApps else { return [] }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let iso = ISO8601DateFormatter()
        var found: [(WrappDTO, Date)] = []
        for name in names where name.hasSuffix(".app") {
            let app = folder.appendingPathComponent(name)
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let modified = (try? fm.attributesOfItem(atPath: app.path)[.modificationDate] as? Date) ?? .distantPast
            found.append((WrappDTO(name: String(name.dropLast(4)), path: app.path, bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                                   modified: modified == .distantPast ? nil : iso.string(from: modified)), modified))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Whether `app` is one of the host's wrapps (in its built-apps folder), which may be changed without asking.
    func isHostWrapp(_ app: URL) -> Bool {
        guard let folder = tools.builtApps else { return false }
        return app.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    // MARK: Try on a wrapp

    public struct TriedIcon: Codable, Sendable {
        var wrapp: String
        var icns: String
    }

    /// Puts a design on a built wrapp, as its `APP --icon` would: its `.icns` in `Contents/Resources/`, named by
    /// `CFBundleIconFile` (with `CFBundleIconName`, the template's asset-catalog icon, removed), the app signed again
    /// ad hoc as a build signs it, and touched so the Dock and Finder look again. Only the host's own wrapps, unless
    /// `anywhere` says the person chose another app themselves.
    public func tryIcon(_ slug: String, doc docData: Data, on wrapp: String, anywhere: Bool) async throws -> TriedIcon {
        let app = URL(fileURLWithPath: wrapp).standardizedFileURL
        let fm = FileManager.default
        guard app.pathExtension == "app", fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw IconLabError.notFound("app \(wrapp)")
        }
        guard anywhere || isHostWrapp(app) else {
            throw IconLabError.invalid("\(app.path) isn't one of the built wrapps; choose it yourself to change it")
        }
        let doc = try JSONDecoder().decode(Doc.self, from: docData)
        let name = slug.isEmpty ? "icon-lab" : slug
        let icns = try await compiledIcns(doc, name: name)
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let target = resources.appendingPathComponent("\(name).icns")
        try icns.write(to: target, options: .atomic)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: &format)
                as? [String: Any] else { throw IconLabError.invalid("\(plistURL.path) isn't a dictionary") }
        plist["CFBundleIconFile"] = target.lastPathComponent
        plist.removeValue(forKey: "CFBundleIconName")
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: plistURL, options: .atomic)
        // signed again as WrappBuildHelper.signWrapp signs a build: its seal covers Info.plist and Resources/
        let signed = try await Process.output(of: "/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        guard signed.succeeded else {
            logger.error("codesign of \(app.path) failed: \(signed.errorOutput)")
            throw IconLabError.tool("the app couldn't be signed again: \(signed.errorOutput.suffix(300))")
        }
        let now = Date()
        for item in [app, app.appendingPathComponent("Contents"), plistURL] {
            do { try fm.setAttributes([.modificationDate: now], ofItemAtPath: item.path) } catch {
                logger.warning("Couldn't touch \(item.path): \(error)")
            }
        }
        logger.notice("Put \(slug)'s design on \(app.path)")
        return TriedIcon(wrapp: app.path, icns: target.path)
    }

    /// The document's `.icon` compiled to `.icns`, the icon named `name` inside it.
    func compiledIcns(_ doc: Doc, name: String) async throws -> Data {
        let icon = try await composer.write(doc)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("icon-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // actool names the app icon by the .icon's file name
        let named = scratch.appendingPathComponent("\(name).icon")
        try FileManager.default.copyItem(at: icon, to: named)
        return try await IconCompile.icns(from: named, name: name)
    }

    // MARK: Save to the bundle

    public struct SavedToBundle: Codable, Sendable {
        var bundle: String
        /// What was written, relative to the bundle's folder: `assets/<name>.icon`, `.icns`, ….
        var files: [String]
        /// Whether `"assets/"` was added to the manifest's allow-paths.
        var allowPathAdded: Bool
        /// Said when the manifest's allow-paths couldn't be changed by itself.
        var manifestNote: String?
        /// The Wrappfile lines that give the app the first icon, when it has no `APP --icon` yet.
        var wrappfileLines: [String]?
        /// Whether `addIconLines` can add them itself (the Wrappfile has one stage).
        var canAddLines: Bool
    }

    /// The program's bundle folder, if the host lets bundles be written and the program came from one.
    func bundleFolder(_ slug: String) async throws -> (id: String, folder: URL) {
        guard let root = host.bundles else { throw IconLabError.invalid("saving to a bundle isn't available here") }
        guard let id = await store.program(slug)?.bundleId else { throw IconLabError.invalid("\(slug) wasn't opened from a bundle") }
        let folder = root.appendingPathComponent(id).standardizedFileURL
        guard !id.contains(".."), folder.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.yaml").path) else {
            throw IconLabError.notFound("bundle \(id)")
        }
        return (id, folder)
    }

    /// Writes the pinned designs `ids`, in order, as the bundle's `assets/<name>.icon`, `<name>-2.icon`, … (`<name>`
    /// its folder's name) with each one's `.icns`, and makes sure the manifest lets the build read `assets/`. Nothing
    /// is committed.
    public func saveToBundle(_ slug: String, ids: [String]) async throws -> SavedToBundle {
        let (id, folder) = try await bundleFolder(slug)
        guard !ids.isEmpty else { throw IconLabError.invalid("no designs to save") }
        let name = folder.lastPathComponent
        let assets = folder.appendingPathComponent("assets")
        let fm = FileManager.default
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        var files: [String] = []
        for (i, docId) in ids.enumerated() {
            guard let data = await store.doc(slug, docId) else { throw IconLabError.notFound("design \(docId)") }
            let doc = try JSONDecoder().decode(Doc.self, from: data)
            let file = i == 0 ? name : "\(name)-\(i + 1)"
            let icon = try await composer.write(doc)
            let iconTarget = assets.appendingPathComponent("\(file).icon")
            if fm.fileExists(atPath: iconTarget.path) { try fm.removeItem(at: iconTarget) }
            try fm.copyItem(at: icon, to: iconTarget)
            try await compiledIcns(doc, name: file).write(to: assets.appendingPathComponent("\(file).icns"), options: .atomic)
            files += ["assets/\(file).icon", "assets/\(file).icns"]
        }
        let manifest = folder.appendingPathComponent("manifest.yaml")
        let (text, added, note) = Self.allowingAssets(try String(contentsOf: manifest, encoding: .utf8))
        if added { try text.write(to: manifest, atomically: true, encoding: .utf8) }
        let wrappfile = (try? String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8)) ?? ""
        let lines = Self.hasIcon(wrappfile) ? nil : Self.iconLines(name)
        logger.notice("Saved \(ids.count) designs to \(id)")
        return SavedToBundle(bundle: id, files: files, allowPathAdded: added, manifestNote: note, wrappfileLines: lines,
                             canAddLines: lines != nil && Self.addingIconLines(wrappfile, name: name) != nil)
    }

    /// Adds the icon lines to the bundle's Wrappfile, after its stage's last LAUNCH; the lines added.
    public func addIconLines(_ slug: String) async throws -> [String] {
        let (_, folder) = try await bundleFolder(slug)
        let file = folder.appendingPathComponent("Wrappfile")
        let text = try String(contentsOf: file, encoding: .utf8)
        guard !Self.hasIcon(text) else { return [] }
        guard let changed = Self.addingIconLines(text, name: folder.lastPathComponent) else {
            throw IconLabError.invalid("the Wrappfile has more than one stage: add the lines yourself")
        }
        try changed.write(to: file, atomically: true, encoding: .utf8)
        return Self.iconLines(folder.lastPathComponent)
    }

    static func iconLines(_ name: String) -> [String] {
        ["COPY bundle:assets/\(name).icns /Resources/\(name).icns", "APP --icon=/Resources/\(name).icns"]
    }

    static func hasIcon(_ wrappfile: String) -> Bool {
        wrappfile.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP") && $0.contains("--icon") }
    }

    /// The Wrappfile with the icon lines after its last LAUNCH (and that instruction's continuation lines), when it
    /// has one stage; nil when it has several, which a person had better place.
    static func addingIconLines(_ wrappfile: String, name: String) -> String? {
        var lines = wrappfile.components(separatedBy: "\n")
        let stages = lines.filter { $0.hasPrefix("FROM ") }.count
        guard stages == 1, var last = lines.lastIndex(where: { $0.hasPrefix("LAUNCH") }) else { return nil }
        while last + 1 < lines.count, lines[last].hasSuffix("\\") { last += 1 }
        lines.insert(contentsOf: ["# Its icon, made in Icon Lab (assets/\(name).icon, compiled by `sc generate`)."] + iconLines(name),
                     at: last + 1)
        return lines.joined(separator: "\n")
    }

    /// The manifest with `"assets/"` in its allow-paths: added to a one-line list, or as a new line after the title
    /// when it has none. Whether it changed, and a note when it couldn't be.
    static func allowingAssets(_ manifest: String) -> (String, Bool, String?) {
        var lines = manifest.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("allow-paths:") }) {
            let line = lines[i]
            if line.contains("\"assets/\"") || line.contains("'assets/'") { return (manifest, false, nil) }
            guard let close = line.firstIndex(of: "]"), line.contains("[") else {
                return (manifest, false, "add \"assets/\" to the manifest's allow-paths yourself")
            }
            let before = line[..<close].trimmingCharacters(in: .whitespaces)
            let separator = before.hasSuffix("[") ? "" : ", "
            lines[i] = line[..<close] + "\(separator)\"assets/\"" + line[close...]
            return (lines.joined(separator: "\n"), true, nil)
        }
        guard let title = lines.lastIndex(where: { $0.hasPrefix("display-name:") }) ?? lines.firstIndex(where: { $0.hasPrefix("title:") }) else {
            return (manifest, false, "add allow-paths: [\"assets/\"] to the manifest yourself")
        }
        lines.insert("allow-paths: [\"assets/\"]   # its icon", at: title + 1)
        return (lines.joined(separator: "\n"), true, nil)
    }
}
