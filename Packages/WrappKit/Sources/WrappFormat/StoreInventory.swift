//
//  StoreInventory.swift
//  WrappFormat
//
//  The kept and cache stores on this Mac, found by where StoreLocations
//  puts them, for `sc store list`, `sc store remove` and `sc clean stores`
//  (decision 23 of the builders plan; docs/wrappfile.md#stores).

import Foundation

/// One store found on disk.
nonisolated public struct FoundStore: Sendable, Equatable {
    public let owner: String
    public let name: String
    /// `keep` or `cache`. Session stores end with their build or launch, so
    /// none is ever found.
    public let retention: String
    /// The app it's for, or nil for a global store.
    public let appID: String?
    public let folder: URL
    /// The lock its declaration names (`--exclusive`), from the record
    /// beside it; nil when it has none, or no record (an app's store a
    /// launch made).
    public let lock: String?
    /// The record beside it (`<name>.store.json`), when there is one.
    public let record: URL?

    /// `owner:name`, as Wrappfiles and messages name it.
    public var fullName: String { "\(owner):\(name)" }
}

nonisolated public enum StoreInventory {
    /// Every kept and cache store under `locations`' roots: the global
    /// ones, then each wrapp's (only Second Chance's own apps' folders, by
    /// their ids). A store with no record beside it takes its lock from
    /// `declaredLocks` (by full name, the modules' declarations), as one an
    /// app migrated in before any build wrote its record.
    public static func all(in locations: StoreLocations, declaredLocks: [String: String] = [:]) -> [FoundStore] {
        var found: [FoundStore] = []
        let sharedRoot = locations.sharedAppSupport.appendingPathComponent("SecondChance/stores", isDirectory: true)
        found += stores(in: sharedRoot, retention: "keep", appID: nil)
        for app in subfolders(of: locations.appSupport) where app.lastPathComponent.hasPrefix(WrappLock.wrappBundleIDPrefix) {
            found += stores(in: app.appendingPathComponent("stores", isDirectory: true), retention: "keep", appID: app.lastPathComponent)
        }
        let cacheRoot = locations.caches.appendingPathComponent("SecondChance/stores", isDirectory: true)
        for scope in subfolders(of: cacheRoot) {
            let appID = scope.lastPathComponent == "global" ? nil : scope.lastPathComponent
            found += stores(in: scope, retention: "cache", appID: appID)
        }
        return found.map { store in
            guard store.lock == nil, let lock = declaredLocks[store.fullName] else { return store }
            return FoundStore(owner: store.owner, name: store.name, retention: store.retention, appID: store.appID,
                              folder: store.folder, lock: lock, record: store.record)
        }
    }

    /// The lock file `store` takes, if its declaration names one: by the
    /// lock's full name (`steam:steam`), global with a global store. The
    /// record doesn't say the lock's own scope, and every lock declared so
    /// far has its store's.
    public static func lockFile(of store: FoundStore, in locations: StoreLocations) -> URL? {
        guard let lock = store.lock else { return nil }
        let parts = lock.split(separator: ":", maxSplits: 1).map(String.init)
        let (owner, name) = parts.count == 2 ? (parts[0], parts[1]) : (store.owner, lock)
        return locations.lockFile(owner: owner, name: name, global: store.appID == nil, appID: store.appID ?? "")
    }

    /// Whether something holds `store`'s lock now: taken and let go again
    /// at once, under a token of its own, when it's free.
    public static func isInUse(_ store: FoundStore, in locations: StoreLocations) -> Bool {
        guard let file = lockFile(of: store, in: locations), FileManager.default.fileExists(atPath: file.path) else { return false }
        let token = UUID()
        guard (try? ProcessLocks.tryTake(file, token: token, holder: "sc store")) == true else { return true }
        ProcessLocks.release(file, token: token)
        return false
    }

    /// `store`'s folder and its record removed.
    public static func remove(_ store: FoundStore) throws {
        try FileManager.default.removeItem(at: store.folder)
        if let record = store.record, FileManager.default.fileExists(atPath: record.path) {
            try FileManager.default.removeItem(at: record)
        }
    }

    /// The stores under `root`, laid out `<owner>/<name>/` with each one's
    /// record beside it; `locks` holds lock files, not stores.
    private static func stores(in root: URL, retention: String, appID: String?) -> [FoundStore] {
        struct Record: Decodable { var lock: String? }
        var found: [FoundStore] = []
        for owner in subfolders(of: root) where owner.lastPathComponent != "locks" {
            for folder in subfolders(of: owner) {
                let name = folder.lastPathComponent
                let record = owner.appendingPathComponent("\(name).store.json")
                let data = FileManager.default.contents(atPath: record.path)
                let lock = data.flatMap { try? JSONDecoder().decode(Record.self, from: $0) }?.lock
                found.append(FoundStore(owner: owner.lastPathComponent, name: name, retention: retention, appID: appID,
                                        folder: folder, lock: lock, record: data == nil ? nil : record))
            }
        }
        return found
    }

    /// The folders in `url`, sorted, links to folders among them (1.1.0's
    /// Steam paths are links into the stores, but those are never inside a
    /// stores folder).
    private static func subfolders(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
