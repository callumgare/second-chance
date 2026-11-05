//
//  InstallersStore.swift
//  WrappBuilder
//
//  Where a Mac keeps the installers its test builds read: disc images and
//  Her Interactive downloads, laid out by program bundle, edition and input.

import Foundation

/// The installers store: one per Mac, at `/Users/Shared/second-chance/installers`
/// (or `$SECOND_CHANCE_INSTALLERS`), read by `sc` and the integration tests,
/// never by Second Chance itself (docs/testing.md#the-installers-store).
///
/// Each file is where its program's manifest says it goes:
/// `<bundle id>/<edition id>/<input name>.<ext>`, such as
/// `nancy-drew/old-clock/cd/disc-1.iso` or
/// `nancy-drew/scarlet-hand/her-windows/installer.exe`. The file read may be
/// a link to one of several alternatives kept beside it under any other
/// name (a full disc image and a cut-down one), and `<bundle id>/extras/`
/// holds what no build reads: guides, manuals, anything else.
public nonisolated struct InstallersStore: Sendable, Hashable {
    public static let environmentVariable = "SECOND_CHANCE_INSTALLERS"
    public static let defaultRoot = SharedFolders.installers
    /// The folder of each program's files no build reads.
    public static let extrasFolder = "extras"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `$SECOND_CHANCE_INSTALLERS` when set, else the Mac's store.
    public static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> InstallersStore {
        if let override = environment[environmentVariable], !override.isEmpty {
            return InstallersStore(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        return InstallersStore(root: defaultRoot)
    }

    /// The input types that are files a person gives, so live in the store.
    public static let fileInputTypes: Set<Manifest.InputType> = [.disc, .herDownload]

    public func folder(program: String) -> URL {
        root.appendingPathComponent(program, isDirectory: true)
    }

    public func folder(program: String, edition: String) -> URL {
        folder(program: program).appendingPathComponent(edition, isDirectory: true)
    }

    public func extras(program: String) -> URL {
        folder(program: program).appendingPathComponent(Self.extrasFolder, isDirectory: true)
    }

    /// The file given as `input`: the one named `<input>.<anything>` in its
    /// edition's folder, through a link if it is one; nil when there's none,
    /// or only a link that leads nowhere.
    public func file(program: String, edition: String, input: String) -> URL? {
        let dir = folder(program: program, edition: edition)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().lazy
            .filter { Self.stem($0) == input }
            .map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One edition whose every file input is in the store.
    public struct Found: Sendable, Hashable {
        public let program: String
        public let edition: String
        public let source: Manifest.Source
        /// Its inputs' files, in the inputs' order (`disc-1`, `disc-2`).
        public let files: [URL]
        /// Its first input's `format`: `windows` or `mac` for a Her download.
        public let format: String?
    }

    /// The editions of `manifest` (from `source`, when given) whose every
    /// file input is in the store; an edition with no file inputs is never
    /// one.
    public func found(_ manifest: Manifest, source: Manifest.Source? = nil) -> [Found] {
        let editions = manifest.editions.filter { source == nil || $0.source == source }
        return editions.compactMap { edition in
            let inputs = Self.fileInputs(of: edition)
            guard !inputs.isEmpty else { return nil }
            var files: [URL] = []
            for input in inputs {
                guard let file = self.file(program: manifest.id, edition: edition.id, input: input.id) else { return nil }
                files.append(file)
            }
            return Found(program: manifest.id, edition: edition.id, source: edition.source, files: files, format: inputs.first?.format)
        }
    }

    /// An edition's inputs that are files, in order.
    /// The program's disc images: its disc edition's `disc-1`, `disc-2`…,
    /// in order; nil unless every one is there.
    public func discs(of manifest: Manifest) -> Found? {
        found(manifest, source: .disc).first
    }

    /// Where the program's disc images go: its disc edition's folder, for a
    /// message saying they aren't there.
    public func discFolder(of manifest: Manifest) -> URL {
        folder(program: manifest.id, edition: manifest.editions.first { $0.source == .disc }?.id ?? "cd")
    }

    /// The program's Her Interactive downloads, one for each of its Her
    /// editions in the store (the Windows installer, the Mac download), in
    /// the manifest's order.
    public func herDownloads(of manifest: Manifest) -> [Found] {
        found(manifest, source: .herDownload)
    }

    public static func fileInputs(of edition: Manifest.Edition) -> [Manifest.Input] {
        (edition.inputs ?? []).filter { fileInputTypes.contains($0.type) }
    }

    /// The editions a listing of a store holds (paths relative to its root,
    /// a line each, as `find` prints them), as `<bundle id>/<edition id>`.
    /// A link is listed as whatever it leads to (`find -L`), so a dangling
    /// one, which `find -L` lists as a link, isn't told apart: rare enough.
    public static func editions(inListing listing: [String], manifests: [Manifest]) -> Set<String> {
        let paths = Set(listing.map { $0.trimmingCharacters(in: .whitespaces) }.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 })
        let stems = Set(paths.map { path -> String in
            let parts = path.split(separator: "/").map(String.init)
            return (parts.dropLast() + [stem(parts.last ?? "")]).joined(separator: "/")
        })
        var found = Set<String>()
        for manifest in manifests {
            for edition in manifest.editions {
                let inputs = fileInputs(of: edition)
                guard !inputs.isEmpty else { continue }
                let present = inputs.allSatisfy { stems.contains("\(manifest.id)/\(edition.id)/\($0.id)") }
                if present { found.insert("\(manifest.id)/\(edition.id)") }
            }
        }
        return found
    }

    /// Every manifest under `bundles` (a repo's `Bundles/`) that loads, in
    /// id order: what the store is laid out by. One that doesn't load is
    /// left out, for `sc bundle check` to report.
    public static func manifests(bundles: URL) -> [Manifest] {
        guard let loader = try? ProgramBundleLoader(root: bundles, modules: nil),
              let folders = try? loader.bundleFolders() else { return [] }
        return folders.compactMap { try? loader.load($0).get().manifest }
    }

    /// A name less its last extension: `disc-1` of `disc-1.iso`.
    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
