//
//  ModuleData.swift
//  WrappBuilder
//
//  Loading and checking modules' data folders, and the record of their
//  releases.

import CryptoKit
import Foundation

/// A module's `module.yaml`: as far as anything reads it so far. The schema
/// (`Modules/module.schema.json`) has every field and checks it first.
public nonisolated struct ModuleManifest: Decodable, Hashable, Sendable {
    public let format: Int
    public let id: String
    public let release: Int
    public let native: String?
    public let versions: [Version]
    public let dependsOn: [String]?
    public let data: [String]?
    public let assets: [String]?
    public let functions: [String]?
    /// Steps run after every final stage that `USE`s the module.
    /// Its default updates, run after a bundle's for a wrapp whose copy of
    /// the module is behind this one (`UpdatePlanner`).
    public let updates: [Update]?

    public struct Version: Decodable, Hashable, Sendable {
        public let version: String
        public let preview: Bool?
        public let withdrawn: Bool?
        public let replacedBy: String?
        /// An engine's: what it is made from (`EnginePackage`).
        public let package: EnginePackage?
    }
}

/// A module's folder, loaded and checked.
public nonisolated struct ModuleFolder: Sendable {
    public let folder: URL
    public let manifest: ModuleManifest

    /// A file the module carries, by its path in the module's folder.
    public func file(_ path: String) -> URL { folder.appendingPathComponent(path) }
}

/// Loads modules from a modules folder (`Modules/` in the repo, the app's
/// resources once shipped), checking each against `module.schema.json`
/// there. Not thread-safe (its validator isn't): make one where it's used.
public nonisolated final class ModuleLoader {
    public let root: URL
    private let validator: SchemaValidator
    /// The `$id`s of the tables' schemas added to `validator` so far.
    private var addedSchemas: Set<String> = []

    static let schemaID = "https://second-chance.invalid/schemas/module.json"

    public init(root: URL) throws {
        self.root = root
        validator = try SchemaValidator()
        try validator.addSchema(Data(contentsOf: root.appendingPathComponent("module.schema.json")))
    }

    /// Every module's folder: `<id>/` or `<namespace>/<name>/`, holding a
    /// `module.yaml`, sorted.
    public func moduleFolders() throws -> [URL] {
        let files = FileManager.default
        var folders: [URL] = []
        for top in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where top.hasDirectoryPath {
            if files.fileExists(atPath: top.appendingPathComponent("module.yaml").path) {
                folders.append(top)
                continue
            }
            for inner in try files.contentsOfDirectory(at: top, includingPropertiesForKeys: nil) where inner.hasDirectoryPath
                && files.fileExists(atPath: inner.appendingPathComponent("module.yaml").path) {
                folders.append(inner)
            }
        }
        return folders.sorted { $0.path < $1.path }
    }

    /// The module in `folder`, or what's wrong with it.
    public func load(_ folder: URL) -> Result<ModuleFolder, ProgramBundleLoader.Problems> {
        let name = folder.path.hasPrefix(root.path + "/") ? String(folder.path.dropFirst(root.path.count + 1)) : folder.path
        func problems(_ messages: [String]) -> Result<ModuleFolder, ProgramBundleLoader.Problems> {
            .failure(.init(all: messages.map { ProgramBundle.Problem(bundle: name, message: $0) }))
        }
        let document: Any
        do {
            document = try YAML12.load(String(contentsOf: folder.appendingPathComponent("module.yaml"), encoding: .utf8))
            let found = try validator.problems(with: document, against: Self.schemaID)
            if !found.isEmpty { return problems(found.map { "module.yaml at \($0)" }) }
        } catch {
            return problems(["module.yaml \(error)"])
        }
        let manifest: ModuleManifest
        do {
            manifest = try Manifest.decodeKebab(ModuleManifest.self, from: document)
        } catch {
            return problems(["module.yaml couldn't be read: \(error)"])
        }
        var messages: [String] = []
        if manifest.id != name {
            messages.append("its id is \(manifest.id), but its folder says \(name)")
        }
        for path in (manifest.data ?? []) + (manifest.assets ?? []) + (manifest.functions ?? [])
            where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) {
            messages.append("names \(path), which isn't in its folder")
        }
        for table in manifest.data ?? [] {
            do {
                let values = try YAML12.load(String(contentsOf: folder.appendingPathComponent(table), encoding: .utf8))
                // A table with a schema beside it (prefix.schema.json) is checked against it.
                let schema = folder.appendingPathComponent((table as NSString).deletingPathExtension + ".schema.json")
                guard FileManager.default.fileExists(atPath: schema.path) else { continue }
                let id = try schemaID(of: schema)
                messages += try validator.problems(with: values, against: id).map { "\(table) at \($0)" }
            } catch {
                messages.append("\(table) \(error)")
            }
        }
        return messages.isEmpty ? .success(ModuleFolder(folder: folder, manifest: manifest)) : problems(messages)
    }

    /// The `$id` of the schema in `file`, added to the validator the first
    /// time it's seen.
    private func schemaID(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["$id"] as? String else {
            throw SchemaValidator.Error(description: "\(file.lastPathComponent) has no $id")
        }
        if !addedSchemas.contains(id) {
            try validator.addSchema(data)
            addedSchemas.insert(id)
        }
        return id
    }

    /// Every module, or every problem with any of them.
    public func loadAll() throws -> Result<[ModuleFolder], ProgramBundleLoader.Problems> {
        var modules: [ModuleFolder] = []
        var all: [ProgramBundle.Problem] = []
        for folder in try moduleFolders() {
            switch load(folder) {
            case .success(let module): modules.append(module)
            case .failure(let problems): all += problems.all
            }
        }
        return all.isEmpty ? .success(modules) : .failure(.init(all: all))
    }

    /// The module with `id`, loaded, or nil when there's none (or it has
    /// problems, which `loadAll` reports).
    public func module(_ id: String) -> ModuleFolder? {
        guard case .success(let module) = load(root.appendingPathComponent(id)) else { return nil }
        return module
    }

    /// One of a module's data tables, as JSON-shaped values: read as YAML
    /// 1.2, as a bundle is.
    public static func table(_ name: String, of module: ModuleFolder) throws -> Any {
        try YAML12.load(String(contentsOf: module.file(name), encoding: .utf8))
    }

    /// A data table decoded into `T`, with its kebab-case keys as camel case.
    public static func table<T: Decodable>(_ name: String, of module: ModuleFolder, as type: T.Type) throws -> T {
        try Manifest.decodeKebab(type, from: table(name, of: module))
    }
}

// MARK: - Releases

/// The record of each module's releases (`Modules/releases.json`): for
/// every release, the versions it provided, its functions and data, and a
/// hash of every file in its folder. A module whose files differ from what
/// its release recorded has changed without a new release, which
/// `sc module check` refuses: a release, once made, never changes.
public nonisolated struct ModuleReleases: Codable, Sendable, Equatable {
    public var modules: [String: [Release]]

    public struct Release: Codable, Sendable, Equatable {
        public var release: Int
        public var versions: [String]
        public var functions: [String]
        public var data: [String]
        /// Each file's sha256, by its path in the module's folder.
        public var files: [String: String]
    }

    public init(modules: [String: [Release]] = [:]) {
        self.modules = modules
    }

    public static func read(from file: URL) throws -> ModuleReleases {
        guard FileManager.default.fileExists(atPath: file.path) else { return ModuleReleases() }
        return try JSONDecoder().decode(ModuleReleases.self, from: Data(contentsOf: file))
    }

    public func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: file)
    }

    /// The module's files as they are, as a release would record them.
    public static func current(_ module: ModuleFolder) throws -> Release {
        let manifest = module.manifest
        return Release(release: manifest.release, versions: manifest.versions.map(\.version),
                       functions: manifest.functions ?? [], data: manifest.data ?? [],
                       files: try hashes(in: module.folder))
    }

    /// What's wrong with the module against its record: changed since its
    /// release was recorded, a release that isn't recorded yet, or a
    /// release that took away what the one before it provided.
    public func problems(with module: ModuleFolder) throws -> [String] {
        let now = try Self.current(module)
        let releases = modules[module.manifest.id] ?? []
        if let recorded = releases.first(where: { $0.release == now.release }) {
            guard recorded.files != now.files else { return [] }
            let changed = Set(recorded.files.keys).union(now.files.keys)
                .filter { recorded.files[$0] != now.files[$0] }.sorted()
            return ["has changed since release \(now.release) was recorded (\(changed.joined(separator: ", "))): "
                    + "raise its release, then run `sc module release \(module.manifest.id)`"]
        }
        var messages = ["release \(now.release) isn't recorded: run `sc module release \(module.manifest.id)`"]
        if let previous = releases.filter({ $0.release < now.release }).max(by: { $0.release < $1.release }) {
            messages += Self.compatibilityProblems(from: previous, to: now)
        } else if let newer = releases.map(\.release).max(), newer > now.release {
            messages.append("its release is \(now.release), but release \(newer) was recorded: releases only count up")
        }
        return messages
    }

    /// Within a version every release is backwards compatible: what a
    /// release provided for a version it still provides, the next one may
    /// not take away. (It may stop providing a version altogether.)
    static func compatibilityProblems(from previous: Release, to next: Release) -> [String] {
        guard !Set(previous.versions).isDisjoint(with: next.versions) else { return [] }
        var messages: [String] = []
        for function in previous.functions where !next.functions.contains(function) {
            messages.append("release \(next.release) drops the function \(function), which release \(previous.release) had: that needs a new version")
        }
        for table in previous.data where !next.data.contains(table) {
            messages.append("release \(next.release) drops the data \(table), which release \(previous.release) had: that needs a new version")
        }
        return messages
    }

    /// Record the module's files as its current release, refusing a
    /// release recorded already with other files.
    public mutating func record(_ module: ModuleFolder) throws {
        let now = try Self.current(module)
        var releases = modules[module.manifest.id] ?? []
        if let index = releases.firstIndex(where: { $0.release == now.release }) {
            guard releases[index].files != now.files else { return }
            throw RecordError(description: "release \(now.release) of \(module.manifest.id) was recorded with other files: raise its release first")
        }
        releases.append(now)
        modules[module.manifest.id] = releases.sorted { $0.release < $1.release }
    }

    public struct RecordError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Every file's sha256 in `folder`, by its relative path, skipping
    /// what Finder leaves behind.
    static func hashes(in folder: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        let base = folder.standardizedFileURL.path + "/"
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return hashes
        }
        for case let file as URL in walk {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  file.lastPathComponent != ".DS_Store" else { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(base.count))
            let digest = SHA256.hash(data: try Data(contentsOf: file))
            hashes[path] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }
}
