import CryptoKit
import Foundation
import WrappBuilder

/// `sc installers migrate`: installers laid out by slug, as they were before
/// the installers store (`<slug>/disk-1.iso`, `<slug>/her-download-….exe`),
/// moved to where their program's manifest says they go
/// (docs/testing.md#the-installers-store). Planned first, so the plan can be
/// shown and nothing is touched until it's agreed.
struct InstallersMigration: Equatable {
    enum Step: Equatable {
        /// Moved: a rename on one volume.
        case move(from: URL, to: URL)
        /// A link made at `at`, leading to `to` (a name beside it), in place
        /// of the old link `replacing`.
        case link(at: URL, to: String, replacing: URL)
        /// Finder's `.DS_Store`, deleted.
        case drop(URL)
        /// A slug's folder, deleted once it's empty.
        case removeFolder(URL)
        /// A checkout's `installers` link, deleted.
        case unlink(URL)
    }

    /// What couldn't be placed, left where it is, and why.
    struct Unplaced: Equatable {
        var item: URL
        var reason: String
    }

    var steps: [Step] = []
    var unplaced: [Unplaced] = []
    /// Placed, but somewhere worth saying (an extra that looked like an
    /// installer).
    var notes: [String] = []

    var isEmpty: Bool { steps.isEmpty }

    // MARK: Planning

    /// The plan for `store`'s own slug folders and, when a checkout is
    /// given, its `installers` (a folder, or a link: to the store, which is
    /// planned once, as the store; to elsewhere, which is planned too).
    static func plan(store: InstallersStore, checkout: URL?, manifests: [Manifest]) -> InstallersMigration {
        var plan = InstallersMigration()
        var planned = Set<String>()
        let files = FileManager.default
        let namespaces = Set(manifests.map(\.namespace))
        let bySlug = Dictionary(manifests.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        func slugFolders(in source: URL, isStore: Bool) {
            for name in sortedNames(source) {
                let item = source.appendingPathComponent(name)
                if name == ".DS_Store" {
                    plan.steps.append(.drop(item))
                    continue
                }
                if isStore && (namespaces.contains(name) || name.hasPrefix(".")) { continue }
                guard isFolder(item), let manifest = bySlug[name] else {
                    plan.unplaced.append(Unplaced(item: item, reason: isFolder(item) ? "no program is called \(name)" : "not in a game's folder"))
                    continue
                }
                plan.slug(item, manifest: manifest, store: store, planned: &planned)
            }
        }

        slugFolders(in: store.root, isStore: true)
        if let checkout {
            let entry = checkout.appendingPathComponent("installers")
            let type = (try? files.attributesOfItem(atPath: entry.path))?[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                let target = entry.resolvingSymlinksInPath()
                if target.standardizedFileURL.path != store.root.resolvingSymlinksInPath().standardizedFileURL.path {
                    slugFolders(in: target, isStore: false)
                }
                plan.steps.append(.unlink(entry))
            } else if type == .typeDirectory {
                slugFolders(in: entry, isStore: false)
                plan.steps.append(.removeFolder(entry))
            }
        }
        return plan
    }

    /// One slug's folder: each file to its edition's input, a link to the
    /// alternative it chooses, the rest to extras.
    private mutating func slug(_ folder: URL, manifest: Manifest, store: InstallersStore, planned: inout Set<String>) {
        let disc = manifest.editions.first { $0.source == .disc }
        let her = manifest.editions.filter { $0.source == .herDownload }
        let extras = store.extras(program: manifest.id)
        var renamed: [String: String] = [:]
        var links: [(URL, String)] = []

        func place(_ item: URL, at destination: URL) {
            let key = destination.standardizedFileURL.path
            if planned.contains(key) || FileManager.default.fileExists(atPath: key) || isLink(destination) {
                unplaced.append(Unplaced(item: item, reason: "\(store.display(destination)) is already taken"))
                return
            }
            planned.insert(key)
            steps.append(.move(from: item, to: destination))
            if destination.deletingLastPathComponent() != extras {
                renamed[item.lastPathComponent] = destination.lastPathComponent
            }
        }

        for name in Self.sortedNames(folder) {
            let item = folder.appendingPathComponent(name)
            let lower = name.lowercased()
            if name == ".DS_Store" {
                steps.append(.drop(item))
                continue
            }
            if let (number, rest) = Self.discImage(name) {
                let input = "disc-\(number)"
                if let disc, InstallersStore.fileInputs(of: disc).contains(where: { $0.id == input }) {
                    let dir = store.folder(program: manifest.id, edition: disc.id)
                    if isLink(item) {
                        links.append((item, input + rest + ".iso"))
                    } else {
                        place(item, at: dir.appendingPathComponent(input + rest + ".iso"))
                    }
                    continue
                }
                notes.append("\(manifest.id): \(name) went to extras, as no disc edition takes \(input).")
            } else if lower.hasPrefix("her-download"), ["exe", "dmg"].contains((lower as NSString).pathExtension), !isLink(item) {
                let format = lower.hasSuffix(".dmg") ? "mac" : "windows"
                let edition = her.first { edition in
                    InstallersStore.fileInputs(of: edition).first?.format == format
                }
                if let edition, let input = InstallersStore.fileInputs(of: edition).first {
                    let destination = store.folder(program: manifest.id, edition: edition.id)
                        .appendingPathComponent(input.id + "." + (lower as NSString).pathExtension)
                    if !planned.contains(destination.standardizedFileURL.path) && !FileManager.default.fileExists(atPath: destination.path) {
                        place(item, at: destination)
                        continue
                    }
                    notes.append("\(manifest.id): \(name) went to extras, as \(edition.id) already has its installer.")
                } else {
                    notes.append("\(manifest.id): \(name) went to extras, as there's no \(format == "mac" ? "Mac" : "Windows") Her download edition.")
                }
            }
            if isLink(item) {
                unplaced.append(Unplaced(item: item, reason: "a link to \((try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "?")"))
                continue
            }
            place(item, at: extras.appendingPathComponent(name))
        }

        // A disc image's link to one of its alternatives, now under its new name.
        for (link, name) in links {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? ""
            guard !target.contains("/"), let newTarget = renamed[target], let disc else {
                unplaced.append(Unplaced(item: link, reason: "a link to \(target), which isn't an image beside it"))
                continue
            }
            let at = store.folder(program: manifest.id, edition: disc.id).appendingPathComponent(name)
            guard planned.insert(at.standardizedFileURL.path).inserted, !FileManager.default.fileExists(atPath: at.path) else {
                unplaced.append(Unplaced(item: link, reason: "\(store.display(at)) is already taken"))
                continue
            }
            steps.append(.link(at: at, to: newTarget, replacing: link))
        }
        let staying = unplaced.contains { $0.item.deletingLastPathComponent() == folder }
        if !staying { steps.append(.removeFolder(folder)) }
    }

    /// `disk-<n>.iso`, or `disk-<n>-<anything>.iso`: its number and the rest
    /// (`-slim`).
    static func discImage(_ name: String) -> (Int, String)? {
        let lower = name.lowercased()
        guard lower.hasPrefix("disk-"), lower.hasSuffix(".iso") else { return nil }
        let middle = name.dropFirst("disk-".count).dropLast(".iso".count)
        let digits = middle.prefix { $0.isNumber }
        guard let number = Int(digits) else { return nil }
        let rest = String(middle.dropFirst(digits.count))
        return rest.isEmpty || rest.hasPrefix("-") ? (number, rest) : nil
    }

    private static func sortedNames(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue && !isLink(url)
    }

    private static func isLink(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func isLink(_ url: URL) -> Bool { Self.isLink(url) }

    // MARK: Carrying it out

    /// Carries the plan out, holding the lock every write into the store
    /// takes (`Remote.installersSyncLock`), so no `--on` sync writes there
    /// meanwhile. A move between volumes copies, checks the copy's MD5
    /// against the original's, and only then deletes the original. Returns
    /// what failed; everything else is done.
    func carryOut(store: InstallersStore, progress: (String) -> Void) throws -> [String] {
        let lock = open(Remote.installersSyncLock, O_RDONLY | O_CREAT, 0o666)
        guard lock >= 0 else { throw SCError("Couldn't open \(Remote.installersSyncLock) to lock the installers store.") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            progress("Waiting for an installers sync into this Mac's store to finish…")
            flock(lock, LOCK_EX)
        }
        let files = FileManager.default
        var failures: [String] = []
        let storeVolume = Self.volume(of: store.root)
        for step in steps {
            do {
                switch step {
                case .move(let from, let to):
                    try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if Self.volume(of: from) == storeVolume {
                        try files.moveItem(at: from, to: to)
                    } else {
                        progress("Copying \(from.lastPathComponent) to another volume…")
                        try files.copyItem(at: from, to: to)
                        guard try Self.sameContents(from, to) else {
                            try? files.removeItem(at: to)
                            throw SCError("the copy of \(from.path) differs from it, so it was left where it was")
                        }
                        try files.removeItem(at: from)
                    }
                case .link(let at, let target, let old):
                    try files.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try files.createSymbolicLink(atPath: at.path, withDestinationPath: target)
                    try files.removeItem(at: old)
                case .drop(let file):
                    try files.removeItem(at: file)
                case .removeFolder(let folder):
                    let left = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
                    if left.isEmpty { try files.removeItem(at: folder) }
                case .unlink(let link):
                    try files.removeItem(at: link)
                }
            } catch {
                failures.append("\(Self.describe(step, store: store)): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private static func volume(of url: URL) -> String? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier).map { "\($0)" }
    }

    /// Whether two files, or two folders file by file, have the same MD5.
    private static func sameContents(_ lhs: URL, _ rhs: URL) throws -> Bool {
        var folder: ObjCBool = false
        FileManager.default.fileExists(atPath: lhs.path, isDirectory: &folder)
        guard folder.boolValue else { return try md5(lhs) == md5(rhs) }
        let names = (FileManager.default.subpaths(atPath: lhs.path) ?? []).sorted()
        for name in names {
            let left = lhs.appendingPathComponent(name)
            FileManager.default.fileExists(atPath: left.path, isDirectory: &folder)
            if !folder.boolValue, try md5(left) != md5(rhs.appendingPathComponent(name)) { return false }
        }
        return true
    }

    private static func md5(_ file: URL) throws -> Insecure.MD5Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize()
    }

    // MARK: Saying it

    static func describe(_ step: Step, store: InstallersStore) -> String {
        switch step {
        case .move(let from, let to): "move \(store.display(from)) → \(store.display(to))"
        case .link(let at, let target, _): "link \(store.display(at)) → \(target)"
        case .drop(let file): "drop \(store.display(file))"
        case .removeFolder(let folder): "remove \(store.display(folder)) once empty"
        case .unlink(let link): "remove the link \(link.path)"
        }
    }

    /// The plan as lines to show: moves and links, then what's removed, the
    /// `.DS_Store` files counted rather than listed.
    func lines(store: InstallersStore) -> [String] {
        var lines = steps.compactMap { step -> String? in
            if case .drop = step { return nil }
            return Self.describe(step, store: store)
        }
        let dropped = steps.filter { if case .drop = $0 { true } else { false } }.count
        if dropped > 0 { lines.append("drop \(dropped) .DS_Store file\(dropped == 1 ? "" : "s")") }
        return lines
    }
}

extension InstallersStore {
    /// A path in the store relative to it; any other, whole.
    func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
