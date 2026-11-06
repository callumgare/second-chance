//
//  ModuleData.swift
//  WrappBuilder
//
//  Loading and checking modules' data folders, and the record of their
//  releases.

import CryptoKit
import Foundation
import WrappModules
import Logging

private nonisolated let addedLogger = Logger(label: "au.gare.callum.second-chance.SecondChance.AddedModules")

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
    /// Data an earlier release had that only the app's own Swift read,
    /// never a bundle, so dropping it needs no new version.
    public let retired: [String]?
    public let assets: [String]?
    public let functions: [String]?
    /// Folders of its own its stages and functions may read files from.
    public let allowPaths: [String]?
    /// Its stages that are Wrappfiles (`stages/prefix`), as a bundle builds
    /// `FROM <module>/<stage>`.
    public let stages: [String]?
    /// Its files of `STORE` and `LOCK` lines (`stores`), which every stage
    /// and function of the module sees.
    public let stores: [String]?
    /// Its files of `SIGNAL` blocks, which its stages and functions, and a
    /// bundle's Wrappfile, name as `<id>.<signal>`.
    public let signals: [String]?
    /// A module someone added: its program, a Mach-O in its folder that
    /// carries out its instructions over the module protocol
    /// (docs/module-programs.md). Shipped modules have none: they're
    /// compiled in.
    public let program: String?
    /// Its default updates, run after a bundle's for a wrapp whose copy of
    /// the module is behind this one (`UpdatePlanner`).
    public let updates: [Update]?
    /// What the wrapp does for a program it runs, which `sc generate`
    /// compiles in (`ModuleDataSource`).
    public let runtime: Runtime?

    public struct Runtime: Decodable, Hashable, Sendable {
        public let saveWarning: Bool?
    }

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
    /// What it adds to a build: its `module.yaml`'s `build:`.
    public let declarations: ModuleDeclarations
    /// The stores and locks its `stores` files declare.
    public let stores: StoreDeclarations
    /// The signals its `signals` files define.
    public let signals: [WrappfileSignal]

    public init(folder: URL, manifest: ModuleManifest, declarations: ModuleDeclarations = .none,
                stores: StoreDeclarations = StoreDeclarations(), signals: [WrappfileSignal] = []) {
        self.folder = folder
        self.manifest = manifest
        self.declarations = declarations
        self.stores = stores
        self.signals = signals
    }

    /// A file the module carries, by its path in the module's folder.
    public func file(_ path: String) -> URL { folder.appendingPathComponent(path) }

    /// The path types it declares, as its own.
    public var pathTypes: [PathType] {
        declarations.pathTypes.map {
            PathType(name: $0.name, module: ModuleID(rawValue: manifest.id), roles: $0.roles, shortForm: $0.shortForm)
        }
    }
}

nonisolated extension PathTypeRegistry {
    /// The path types `modules` declare: all a build knows of. A module
    /// someone adds brings its own as a shipped one does.
    public init(modules: [ModuleFolder]) {
        self.init(modules.flatMap(\.pathTypes))
    }
}

/// Loads modules from a modules folder (`Modules/` in the repo, the app's
/// resources once shipped), checking each against `module.schema.json`
/// there. Not thread-safe (its validator isn't): make one where it's used.
public nonisolated final class ModuleLoader {
    public let root: URL
    /// The modules someone added (`<namespace>/<name>/`), loaded after the
    /// shipped ones, which a module of the same id never shadows.
    public let added: URL?
    private let validator: SchemaValidator
    /// The `$id`s of the tables' schemas added to `validator` so far.
    private var addedSchemas: Set<String> = []

    static let schemaID = "https://second-chance.invalid/schemas/module.json"

    public init(root: URL, added: URL? = nil) throws {
        self.root = root
        self.added = added
        validator = try SchemaValidator()
        try validator.addSchema(Data(contentsOf: root.appendingPathComponent("module.schema.json")))
    }

    /// Every module's folder: `<id>/` or `<namespace>/<name>/`, holding a
    /// `module.yaml`, sorted.
    public func moduleFolders() throws -> [URL] { try Self.folders(in: root) }

    /// The module folders in `root`: `<id>/` or `<namespace>/<name>/`.
    static func folders(in root: URL) throws -> [URL] {
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
        // Both resolved, as a temporary folder may be named by /var or /private/var.
        let path = folder.resolvingSymlinksInPath().path
        let addedPath = added?.resolvingSymlinksInPath().path
        let rootPath = addedPath.map { path.hasPrefix($0 + "/") } == true ? addedPath ?? "" : root.resolvingSymlinksInPath().path
        let name = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : folder.path
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
        var declarations = ModuleDeclarations.none
        do {
            declarations = try ModuleDeclarations((document as? [String: Any])?["build"])
        } catch {
            messages.append("module.yaml's build: \(error.description)")
        }
        if manifest.id != name {
            messages.append("its id is \(manifest.id), but its folder says \(name)")
        }
        let named: [[String]?] = [manifest.data, manifest.assets, manifest.functions, manifest.stores, manifest.signals]
        for path in named.flatMap({ $0 ?? [] })
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
        var stores = StoreDeclarations()
        for path in manifest.stores ?? [] {
            do {
                let parsed = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8))
                if !parsed.stages.isEmpty || !parsed.functions.isEmpty || !parsed.globals.isEmpty {
                    messages.append("\(path) holds only STORE and LOCK lines")
                }
                stores.merge(try StoreDeclarations.parse(parsed.storeDeclarations, module: manifest.id, origin: "\(manifest.id)/\(path)"))
            } catch let error as StoreDeclarations.Problem {
                messages.append(error.description)
            } catch {
                messages.append("\(path) \(error)")
            }
        }
        var signals: [WrappfileSignal] = []
        for path in manifest.signals ?? [] {
            do {
                let parsed = try WrappfileParser.parse(String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8))
                if !parsed.stages.isEmpty || !parsed.functions.isEmpty || !parsed.globals.isEmpty || !parsed.storeDeclarations.isEmpty {
                    messages.append("\(path) holds only SIGNAL blocks")
                }
                signals += parsed.signals
            } catch {
                messages.append("\(path) \(error)")
            }
        }
        return messages.isEmpty
            ? .success(ModuleFolder(folder: folder, manifest: manifest, declarations: declarations, stores: stores, signals: signals))
            : problems(messages)
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
        modules += addedModules(besides: modules)
        return all.isEmpty ? .success(modules) : .failure(.init(all: all))
    }

    /// The modules someone added that load, each namespaced and none
    /// shadowing a shipped one: one that doesn't is left out, and logged,
    /// rather than stopping every build.
    public func addedModules(besides shipped: [ModuleFolder]) -> [ModuleFolder] {
        guard let added, FileManager.default.fileExists(atPath: added.path) else { return [] }
        let folders = (try? Self.folders(in: added)) ?? []
        var modules: [ModuleFolder] = []
        for folder in folders {
            switch load(folder) {
            case .success(let module) where !module.manifest.id.contains("/"):
                addedLogger.warning("Leaving out the added module \(module.manifest.id): an added module's id is namespaced (<namespace>/<name>)")
            case .success(let module) where shipped.contains(where: { $0.manifest.id == module.manifest.id }):
                addedLogger.warning("Leaving out the added module \(module.manifest.id): a shipped module has its id")
            case .success(let module):
                modules.append(module)
            case .failure(let problems):
                addedLogger.warning("Leaving out an added module: \(problems.all.map(\.description).joined(separator: "; "))")
            }
        }
        return modules
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
            messages += Self.compatibilityProblems(from: previous, to: now, retired: module.manifest.retired ?? [])
        } else if let newer = releases.map(\.release).max(), newer > now.release {
            messages.append("its release is \(now.release), but release \(newer) was recorded: releases only count up")
        }
        return messages
    }

    /// Within a version every release is backwards compatible: what a
    /// release provided for a version it still provides, the next one may
    /// not take away. (It may stop providing a version altogether.) Data the
    /// module says is `retired` was never a bundle's to read, so may go.
    static func compatibilityProblems(from previous: Release, to next: Release, retired: [String] = []) -> [String] {
        guard !Set(previous.versions).isDisjoint(with: next.versions) else { return [] }
        var messages: [String] = []
        for function in previous.functions where !next.functions.contains(function) {
            messages.append("release \(next.release) drops the function \(function), which release \(previous.release) had: that needs a new version")
        }
        for table in previous.data where !next.data.contains(table) && !retired.contains(table) {
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
