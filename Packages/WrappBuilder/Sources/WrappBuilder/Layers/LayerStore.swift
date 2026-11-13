//
//  LayerStore.swift
//  WrappBuilder
//
//  Cached layers of a build: what a step made, kept by its key so the next
//  build that would make the same thing clones it instead.

import Foundation
import ProcessKit

/// The layer cache (docs/wrapp-build.md#the-layer-cache): each layer a
/// folder the build made, named by its key's hash, with the key's inputs,
/// when it was made and last used, and the events its steps published:
///
/// ```text
/// <root>/<hash>/
///   content/     what the layer holds (a prefix, a wrapp's SharedSupport)
///   key.json     its `LayerKey`, inputs and all
///   meta.json    made, last used, size
///   events.json  what its steps published, given back on a hit
/// ```
///
/// A layer is made under a hidden name and renamed into place whole, so
/// nothing ever finds half of one. Two builds wanting the same layer, in one
/// process or two, take a lock on its key: one makes it, and the other then
/// finds it. Restoring clones it (`clonefile`), which costs nothing until
/// either copy changes a file.
public nonisolated final class LayerStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Caches/SecondChance/layers`: where macOS may empty it when
    /// the disk is nearly full, and Time Machine leaves it out.
    public static func standard() -> LayerStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return LayerStore(root: caches.appendingPathComponent("SecondChance/layers", isDirectory: true))
    }

    public struct Layer: Sendable {
        public let key: LayerKey
        /// What the layer holds.
        public let content: URL
        /// What its steps published, as they were given to `layer(for:)`.
        public let events: Data?
    }

    public struct Meta: Codable, Sendable, Equatable {
        public var created: Date
        public var lastUsed: Date
        /// Bytes its content takes on disk, as made.
        public var size: Int64
    }

    /// How a layer reached where it was restored to.
    public enum Restored: Sendable, Equatable {
        /// Cloned: shares its blocks with the layer.
        case cloned
        /// Copied, as the store and the destination are on different
        /// volumes; the build says so in its log.
        case copied
    }

    // MARK: - Looking up and making

    func folder(_ hash: String) -> URL { root.appendingPathComponent(hash, isDirectory: true) }

    /// The layer for `key`, if the store has it; its last use is now.
    public func lookup(_ key: LayerKey, now: Date = Date()) -> Layer? {
        let folder = folder(key.hash)
        let content = folder.appendingPathComponent("content")
        guard FileManager.default.fileExists(atPath: content.path) else { return nil }
        touch(folder, now: now)
        return Layer(key: key, content: content, events: try? Data(contentsOf: folder.appendingPathComponent("events.json")))
    }

    /// The layer for `key`: the store's, or else made by `make`, which fills
    /// the folder it's given and returns the events to keep with it. A
    /// build that wants a layer another build is making waits for that one.
    /// `built` says whether `make` ran.
    public func layer(
        for key: LayerKey,
        now: @escaping @Sendable () -> Date = { Date() },
        make: (URL) async throws -> Data?
    ) async throws -> (layer: Layer, built: Bool) {
        let lock = try await Self.lock(root.appendingPathComponent(".locks/\(key.hash).lock"))
        defer { lock.release() }
        if let layer = lookup(key, now: now()) { return (layer, false) }
        let incoming = root.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        let files = FileManager.default
        do {
            try files.createDirectory(at: incoming, withIntermediateDirectories: true)
            let content = incoming.appendingPathComponent("content", isDirectory: true)
            let events = try await make(content)
            guard files.fileExists(atPath: content.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: content.path])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(key).write(to: incoming.appendingPathComponent("key.json"))
            if let events { try events.write(to: incoming.appendingPathComponent("events.json")) }
            let made = now()
            let meta = Meta(created: made, lastUsed: made, size: Self.allocatedSize(of: content))
            try encoder.encode(meta).write(to: incoming.appendingPathComponent("meta.json"))
            let destination = folder(key.hash)
            if files.fileExists(atPath: destination.path) { try FileTree.remove(destination) }
            try files.moveItem(at: incoming, to: destination)
        } catch {
            try? FileTree.remove(incoming)
            throw error
        }
        guard let layer = lookup(key, now: now()) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder(key.hash).path])
        }
        return (layer, true)
    }

    /// Put `layer`'s content at `destination`, which mustn't exist.
    public func restore(_ layer: Layer, to destination: URL) throws -> Restored {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(layer.content.path, destination.path, 0) == 0 { return .cloned }
        try FileManager.default.copyItem(at: layer.content, to: destination)
        return .copied
    }

    // MARK: - Explaining a miss

    /// Why `key` isn't in the store, in words: the inputs that differ from
    /// the layer last used for the same slot, or that there is none. Nil
    /// when it is.
    public func explain(_ key: LayerKey) -> String? {
        if FileManager.default.fileExists(atPath: folder(key.hash).appendingPathComponent("content").path) { return nil }
        let nearest = storedKeys()
            .filter { $0.key.slot == key.slot }
            .max { $0.meta.lastUsed < $1.meta.lastUsed }
        guard let nearest else { return "no \(key.slot) layer is cached" }
        let changes = key.differences(from: nearest.key)
        guard !changes.isEmpty else { return "the cached \(key.slot) layer was made from the same inputs, but under another key" }
        return changes.joined(separator: ", ")
    }

    /// Every layer's key and meta.
    public func storedKeys() -> [(key: LayerKey, meta: Meta)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { folder in
            guard !folder.lastPathComponent.hasPrefix("."),
                  let key = try? decoder.decode(LayerKey.self, from: Data(contentsOf: folder.appendingPathComponent("key.json"))),
                  let meta = try? decoder.decode(Meta.self, from: Data(contentsOf: folder.appendingPathComponent("meta.json")))
            else { return nil }
            return (key, meta)
        }
    }

    // MARK: - Pruning

    /// The store's limits: a layer unused for `maxAge` goes, and so do the
    /// least recently used beyond `sizeLimit`.
    public struct Limits: Sendable {
        public var maxAge: TimeInterval
        public var sizeLimit: Int64

        public init(maxAge: TimeInterval = 30 * 24 * 3600, sizeLimit: Int64 = 40 << 30) {
            self.maxAge = maxAge
            self.sizeLimit = sizeLimit
        }
    }

    /// Remove what `limits` says has to go, at most once a day (`force`
    /// aside), under the store's lock; skipped when another process is
    /// pruning. The hashes removed.
    ///
    /// A layer's size is what it took when made; one that shares its blocks
    /// with a wrapp frees less than that when it goes.
    @discardableResult
    public func prune(limits: Limits = Limits(), now: Date = Date(), force: Bool = false) -> [String] {
        let files = FileManager.default
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".last-prune")
        if !force, let last = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           now.timeIntervalSince(last) < 24 * 3600 {
            return []
        }
        guard let lock = Self.tryLock(root.appendingPathComponent(".locks/prune.lock")) else { return [] }
        defer { lock.release() }
        files.createFile(atPath: marker.path, contents: nil)
        try? files.setAttributes([.modificationDate: now], ofItemAtPath: marker.path)

        var removed: [String] = []
        var kept: [(hash: String, meta: Meta)] = []
        for (key, meta) in storedKeys() {
            if now.timeIntervalSince(meta.lastUsed) > limits.maxAge, remove(key.hash) {
                removed.append(key.hash)
            } else {
                kept.append((key.hash, meta))
            }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.meta.size }
        for layer in kept.sorted(by: { $0.meta.lastUsed < $1.meta.lastUsed }) where total > limits.sizeLimit {
            if remove(layer.hash) {
                removed.append(layer.hash)
                total -= layer.meta.size
            }
        }
        // What a build that died left half made.
        for entry in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where entry.lastPathComponent.hasPrefix(".incoming-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 24 * 3600 { try? FileTree.remove(entry) }
        }
        return removed
    }

    /// Remove a layer, unless a build is making or using it now.
    private func remove(_ hash: String) -> Bool {
        guard let lock = Self.tryLock(root.appendingPathComponent(".locks/\(hash).lock")) else { return false }
        defer { lock.release() }
        return (try? FileTree.remove(folder(hash))) != nil
    }

    /// Remove every layer (`sc clean layers`).
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileTree.remove(root)
        }
    }

    // MARK: - Helpers

    private func touch(_ folder: URL, now: Date) {
        let file = folder.appendingPathComponent("meta.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var meta = try? decoder.decode(Meta.self, from: Data(contentsOf: file)) else { return }
        meta.lastUsed = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(meta).write(to: file, options: .atomic)
    }

    static func allocatedSize(of folder: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// An exclusive `flock` on a file: held by the open file, so released if
    /// the process dies, and exclusive between two opens in one process too.
    struct FileLock: Sendable {
        let descriptor: Int32

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    static func open(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    /// Wait for the lock, off the calling thread.
    static func lock(_ url: URL) async throws -> FileLock {
        let descriptor = try open(url)
        try await Blocking.run {
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    close(descriptor)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return FileLock(descriptor: descriptor)
    }

    /// The lock, or nil if someone has it.
    static func tryLock(_ url: URL) -> FileLock? {
        guard let descriptor = try? open(url) else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return FileLock(descriptor: descriptor)
    }
}
