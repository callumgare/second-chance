//
//  ProgramBundle.swift
//  WrappBuilder
//
//  Loading and checking program bundles.

import Foundation

/// A program bundle: a folder with a `manifest.yaml`, laid out as
/// `<namespace>/<name>/` under a bundles folder whose `manifest.schema.json`
/// the manifest is checked against.
public nonisolated struct ProgramBundle: Sendable {
    public let folder: URL
    public let manifest: Manifest

    /// What's wrong with a bundle, as its author would be told.
    public struct Problem: Error, Hashable, CustomStringConvertible {
        /// The bundle's folder, as given.
        public let bundle: String
        public let message: String

        public var description: String { "\(bundle): \(message)" }

        public init(bundle: String, message: String) {
            self.bundle = bundle
            self.message = message
        }
    }

    /// The `$id` of the manifest schema.
    static let manifestSchemaID = "https://second-chance.invalid/schemas/manifest.json"
}

/// Loads bundles from a bundles folder, checking each against the schema
/// there. Not thread-safe (its validator isn't): make one where it's used.
public nonisolated final class ProgramBundleLoader {
    public let root: URL
    private let validator: SchemaValidator
    /// The modules a bundle's Wrappfile is checked against; nil to leave
    /// Wrappfiles unchecked, for what reads only manifests (recognising a
    /// disc), as the shipped bundles were checked before they shipped.
    private let modules: [ModuleFolder]?

    /// A loader for the bundles under `root`, which holds
    /// `manifest.schema.json`, checking their Wrappfiles against `modules`,
    /// or not at all when it is nil.
    public init(root: URL, modules: [ModuleFolder]?) throws {
        self.root = root
        self.modules = modules
        validator = try SchemaValidator()
        let schema = root.appendingPathComponent("manifest.schema.json")
        try validator.addSchema(Data(contentsOf: schema))
    }

    /// Every bundle's folder under the root: `<namespace>/<name>/` with a
    /// `manifest.yaml`, sorted by id.
    public func bundleFolders() throws -> [URL] {
        let files = FileManager.default
        var folders: [URL] = []
        for namespace in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) where namespace.hasDirectoryPath {
            for folder in try files.contentsOfDirectory(at: namespace, includingPropertiesForKeys: [.isDirectoryKey]) where folder.hasDirectoryPath {
                if files.fileExists(atPath: folder.appendingPathComponent("manifest.yaml").path) {
                    folders.append(folder)
                }
            }
        }
        return folders.sorted { $0.path < $1.path }
    }

    /// The manifest in `folder` as YAML 1.2 reads it, unchecked: what
    /// `ManifestQuery` matches.
    public func document(in folder: URL) throws -> Any {
        try YAML12.load(String(contentsOf: folder.appendingPathComponent("manifest.yaml"), encoding: .utf8))
    }

    /// The bundle in `folder`, or the problems that stop it loading.
    public func load(_ folder: URL) -> Result<ProgramBundle, Problems> {
        let name = folder.path.hasPrefix(root.path + "/") ? String(folder.path.dropFirst(root.path.count + 1)) : folder.path
        func problems(_ messages: [String]) -> Result<ProgramBundle, Problems> {
            .failure(Problems(all: messages.map { ProgramBundle.Problem(bundle: name, message: $0) }))
        }
        let document: Any
        do {
            let text = try String(contentsOf: folder.appendingPathComponent("manifest.yaml"), encoding: .utf8)
            document = try YAML12.load(text)
        } catch {
            return problems(["manifest.yaml \(error)"])
        }
        let schemaProblems: [SchemaValidator.Problem]
        do {
            schemaProblems = try validator.problems(with: document, against: ProgramBundle.manifestSchemaID)
        } catch {
            return problems(["manifest.yaml couldn't be checked: \(error)"])
        }
        if !schemaProblems.isEmpty {
            return problems(schemaProblems.map { "manifest.yaml at \($0)" })
        }
        let manifest: Manifest
        do {
            manifest = try Manifest.decode(document)
        } catch {
            return problems(["manifest.yaml couldn't be read: \(error)"])
        }
        var messages = Self.problems(with: manifest, in: folder)
        if let modules {
            messages += wrappfileProblems(manifest, in: folder, modules: modules)
        }
        if !messages.isEmpty { return problems(messages) }
        return .success(ProgramBundle(folder: folder, manifest: manifest))
    }

    /// Every bundle under the root, or every problem with any of them.
    public func loadAll() throws -> Result<[ProgramBundle], Problems> {
        var bundles: [ProgramBundle] = []
        var all: [ProgramBundle.Problem] = []
        for folder in try bundleFolders() {
            switch load(folder) {
            case .success(let bundle): bundles.append(bundle)
            case .failure(let problems): all += problems.all
            }
        }
        var seen: [String: String] = [:]
        for bundle in bundles {
            if let other = seen.updateValue(bundle.folder.lastPathComponent, forKey: bundle.manifest.id) {
                all.append(.init(bundle: bundle.manifest.id, message: "is the id of two bundles (\(other) too)"))
            }
        }
        return all.isEmpty ? .success(bundles) : .failure(Problems(all: all))
    }

    public struct Problems: Error, CustomStringConvertible {
        public let all: [ProgramBundle.Problem]
        public var description: String { all.map(\.description).joined(separator: "\n") }
    }

    /// What's wrong with the bundle's Wrappfile, which a bundle with editions
    /// to build has (every one does, but one whose only edition is Steam's).
    func wrappfileProblems(_ manifest: Manifest, in folder: URL, modules: [ModuleFolder]) -> [String] {
        let file = folder.appendingPathComponent("Wrappfile")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            let needed = manifest.editions.contains { $0.build?.target != nil }
            return needed ? ["has editions to build but no Wrappfile"] : []
        }
        do {
            let parsed = try WrappfileParser.parse(text)
            let problems = WrappfileChecker(manifest: manifest, bundleFolder: folder, modules: modules).problems(parsed)
            if !problems.isEmpty { return problems.map { "Wrappfile \($0)" } }
            // What only a plan shows: every edition's target planned.
            return BuildPlanner(bundle: ProgramBundle(folder: folder, manifest: manifest), wrappfile: parsed, modules: modules)
                .problemsPlanningEveryTarget().map { "Wrappfile \($0)" }
        } catch {
            return ["Wrappfile \(error)"]
        }
    }

    /// What the checker warns about in the bundle's Wrappfile: nothing that
    /// stops it loading, but worth saying (`sc bundle check`).
    public func warnings(_ folder: URL) -> [String] {
        guard let modules, case .success(let bundle) = load(folder),
              let text = try? String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8),
              let parsed = try? WrappfileParser.parse(text) else { return [] }
        return WrappfileChecker(manifest: bundle.manifest, bundleFolder: folder, modules: modules).warnings(parsed)
            .map { "Wrappfile \($0)" }
    }

    /// What the schema can't check: rules across fields and the folder.
    static func problems(with manifest: Manifest, in folder: URL) -> [String] {
        var messages: [String] = []
        let expected = "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)"
        if manifest.id != expected {
            messages.append("its id is \(manifest.id), but its folder says \(expected)")
        }
        for (kind, ids) in [("edition", manifest.editions.map(\.id))] {
            for id in Set(ids) where ids.count(where: { $0 == id }) > 1 {
                messages.append("has two \(kind)s called \(id)")
            }
        }
        // What each source's inputs can be: its own kind, and choices.
        let kinds: [Manifest.Source: Manifest.InputType] = [
            .disc: .disc, .herDownload: .herDownload, .steam: .steamGame, .bigFish: .bigFishGame, .download: .download,
        ]
        for edition in manifest.editions {
            for input in edition.build?.inputs ?? [] where input.type != .choice && input.type != kinds[edition.source] {
                messages.append("edition \(edition.id) is a \(edition.source.rawValue) edition, so its input \(input.id) can't be a \(input.type.rawValue)")
            }
        }
        return messages.sorted()
    }
}
