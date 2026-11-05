//
//  EngineStore.swift
//  WrappBuilder
//
//  Prepared engines, kept once per Mac by their prepared hash, so each is
//  fetched and prepared only the first time a build needs it.

import Foundation
import ProcessKit

/// The engines this Mac has prepared (docs/modules.md#the-engine-store),
/// each a tree named by its package's prepared hash:
///
/// ```text
/// <root>/<prepared hash>/   SharedSupport/wine/…, Frameworks/…, Resources/engines/wine.files
/// ```
///
/// An engine is prepared under a hidden name and renamed into place whole,
/// so nothing finds half of one, and two builds wanting the same engine, in
/// one process or two, take a lock on its hash: one prepares it, and the
/// other then finds it. It is a cache, which macOS may empty: a wrapp holds
/// its own copy of its engine, so nothing but the next build needs it, and
/// that prepares it again.
public nonisolated final class EngineStore: Sendable {
    public typealias Prepare = @Sendable (ModuleFolder, String, URL, @escaping @Sendable (String) -> Void) async throws -> String

    public let root: URL
    /// Prepares `version` of the module into the folder given, returning
    /// the tree's hash: `EnginePreparer.prepare`, unless a test gives
    /// another.
    let prepare: Prepare

    public init(root: URL, preparer: EnginePreparer) {
        self.root = root
        prepare = { module, version, tree, progress in
            try await preparer.prepare(module, version: version, into: tree, progress: progress).hash
        }
    }

    init(root: URL, prepare: @escaping Prepare) {
        self.root = root
        self.prepare = prepare
    }

    /// This user's store, `~/Library/Caches/SecondChance/engines`, or on a
    /// Mac with test users (`sharedRoot`) the one they all share.
    public static func standardRoot() -> URL {
        sharedRootIfUsable() ?? userRoot()
    }

    /// `~/Library/Caches/SecondChance/engines`.
    public static func userRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("SecondChance/engines", isDirectory: true)
    }

    /// One store for every user on a Mac with test users, so each test
    /// account doesn't fetch and prepare every engine again: the Mac's pool
    /// file (`sc session`) says it has them. Every user can write it, through
    /// an inheriting ACL set when it's made, so an engine another user
    /// prepared is used only once its hash checks out (`engine`).
    public static let sharedRoot = SharedFolders.engines
    static let poolFile = SharedFolders.pool

    /// The shared store, when this Mac has test users and this user can
    /// write it (or make it); nil means this user's own.
    static func sharedRootIfUsable(shared: URL = sharedRoot, pool: URL = poolFile) -> URL? {
        let files = FileManager.default
        guard files.fileExists(atPath: pool.path) else { return nil }
        if files.fileExists(atPath: shared.path) { return files.isWritableFile(atPath: shared.path) ? shared : nil }
        return files.isWritableFile(atPath: shared.deletingLastPathComponent().path) ? shared : nil
    }

    /// An engine in the store.
    public struct Engine: Sendable, Equatable {
        public let module: String
        public let version: String
        /// Its package's prepared hash, which names it.
        public let hash: String
        /// Laid out as a wrapp's `Contents/`.
        public let tree: URL
        /// Whether this call prepared it.
        public let prepared: Bool
    }

    /// The tree of `version` of `module` (its newest with a package when
    /// nil): the store's, or prepared now. `progress` hears each step of a
    /// preparation, in words for the log and `sc`.
    public func engine(_ module: ModuleFolder, version: String? = nil,
                       progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Engine {
        let id = module.manifest.id
        guard let (version, package) = module.manifest.package(version: version) else {
            throw EngineError("\(id) has no engine package\(version.map { " for version \($0)" } ?? "")")
        }
        guard let hash = package.prepared else {
            throw EngineError("\(id) \(version)'s package names no prepared hash: run `sc engine prepare \(id)` and add it")
        }
        try await makeRoot()
        let lock = try await LayerStore.lock(lockFile(hash))
        defer { lock.release() }
        let tree = folder(hash)
        if Self.isWhole(tree, module: id), Self.isTrusted(tree, hash: hash) {
            touch(tree)
            return Engine(module: id, version: version, hash: hash, tree: tree, prepared: false)
        }
        let files = FileManager.default
        if files.fileExists(atPath: tree.path) { try files.removeItem(at: tree) }
        let incoming = root.appendingPathComponent("\(Self.incomingPrefix)\(hash)-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            let made = try await prepare(module, version, incoming, progress)
            guard made == hash else {
                throw EngineError("\(id) \(version) prepared as \(made), not the \(hash) its package says")
            }
            try files.moveItem(at: incoming, to: tree)
        } catch {
            try? files.removeItem(at: incoming)
            throw error
        }
        return Engine(module: id, version: version, hash: hash, tree: tree, prepared: true)
    }

    /// The store's folder, made shareable if it's the shared one.
    func makeRoot() async throws {
        if root.standardizedFileURL.path == Self.sharedRoot.path {
            try await SharedFolders.make(root)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    /// Whether an engine found in the store can be used as it is: one this
    /// user prepared, or one whose tree hashes to its package's prepared
    /// hash. In the shared store another user could have changed one, and a
    /// wrapp signs and runs what it copies.
    static func isTrusted(_ tree: URL, hash: String, user: uid_t = getuid()) -> Bool {
        guard let owner = (try? FileManager.default.attributesOfItem(atPath: tree.path))?[.ownerAccountID] as? NSNumber,
              owner.uint32Value != user else { return true }
        return (try? EngineTree.hash(of: tree)) == hash
    }

    /// A preparation's folder until it is whole: `.incoming-<hash>-<uuid>`.
    static let incomingPrefix = ".incoming-"

    func folder(_ hash: String) -> URL {
        root.appendingPathComponent(hash, isDirectory: true)
    }

    func lockFile(_ hash: String) -> URL {
        root.appendingPathComponent(".locks/\(hash).lock")
    }

    /// Whether every file the tree's list names is there: macOS emptying
    /// the cache, or someone clearing part of it, can leave a tree short.
    static func isWhole(_ tree: URL, module: String) -> Bool {
        let list = tree.appendingPathComponent(EngineTree.listPath(module: module))
        guard let text = try? String(contentsOf: list, encoding: .utf8) else { return false }
        let paths = text.split(separator: "\n")
        return !paths.isEmpty && paths.allSatisfy { path in
            var info = stat()
            return lstat(tree.appendingPathComponent(String(path)).path, &info) == 0
        }
    }

    /// Mark the tree as used now.
    func touch(_ tree: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: tree.path)
    }

    // MARK: - Pruning

    /// Remove every engine in the store but those `keep` names by hash
    /// (what the modules list now), and what preparations that stopped
    /// partway left. An engine being prepared holds its hash's lock, so one
    /// whose lock is taken is left alone. Returns the hashes removed.
    @discardableResult
    public func prune(keeping keep: Set<String>) throws -> [String] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for name in entries.sorted() where name != ".locks" {
            let incoming = name.hasPrefix(Self.incomingPrefix)
            // A hash has no dashes, so it ends at the first.
            let hash = incoming ? String(name.dropFirst(Self.incomingPrefix.count).prefix { $0 != "-" }) : name
            guard incoming || !keep.contains(hash) else { continue }
            guard let lock = LayerStore.tryLock(lockFile(hash)) else { continue }
            defer { lock.release() }
            try files.removeItem(at: root.appendingPathComponent(name))
            if !incoming { removed.append(hash) }
        }
        return removed
    }

    /// The hashes of every listed version's package across `modules`, as
    /// `prune` keeps them.
    public static func listedHashes(in modules: [ModuleFolder]) -> Set<String> {
        Set(modules.flatMap { $0.manifest.versions.compactMap { $0.package?.prepared } })
    }
}
