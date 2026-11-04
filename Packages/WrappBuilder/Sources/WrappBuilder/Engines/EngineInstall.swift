//
//  EngineInstall.swift
//  WrappBuilder
//
//  Putting a prepared engine into a wrapp, and taking it out again.

import Darwin
import Foundation

/// An engine in a wrapp: its files cloned from the store's tree into the
/// wrapp's `Contents/`, with the tree's list of them
/// (`Resources/engines/<module>.files`) and a record of which engine it is
/// (`Resources/engines/<module>.json`). The list is what taking it out
/// again removes, so an engine leaves nothing of itself behind and touches
/// nothing of the launcher's.
public nonisolated enum EngineInstall {
    /// Which engine a wrapp holds.
    public struct Record: Codable, Sendable, Equatable {
        public let module: String
        public let version: String
        /// Its package's prepared hash.
        public let hash: String

        public init(module: String, version: String, hash: String) {
            self.module = module
            self.version = version
            self.hash = hash
        }
    }

    public static func recordPath(module: String) -> String {
        "Resources/engines/\(module).json"
    }

    /// Clone `engine`'s tree into the wrapp's `contents`. A folder the
    /// wrapp doesn't have yet is cloned whole; a file the wrapp has already
    /// is the launcher's, and stops the install rather than being replaced.
    /// Across volumes, where a clone can't be made, the files are copied.
    public static func install(_ engine: EngineStore.Engine, into contents: URL) throws {
        let files = FileManager.default
        // Each folder cloned whole. Not only the last: entries sort `-`
        // before `/`, so `mapping/ASCII.TXT` comes after `mapping-unicode.org`.
        var cloned: Set<String> = []
        for entry in try EngineTree.entries(in: engine.tree) where !EngineTree.isBuildTool(entry.path) {
            if Self.folders(above: entry.path).contains(where: cloned.contains) { continue }
            let source = engine.tree.appendingPathComponent(entry.path)
            let destination = contents.appendingPathComponent(entry.path)
            var info = stat()
            let exists = lstat(destination.path, &info) == 0
            if entry.kind == .directory {
                guard !exists else { continue }
                try place(source, at: destination)
                cloned.insert(entry.path)
                continue
            }
            if exists {
                throw EngineError("\(engine.module)'s \(entry.path) is already in the app: the launcher has a file of the same name")
            }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try place(source, at: destination)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let record = Record(module: engine.module, version: engine.version, hash: engine.hash)
        try encoder.encode(record).write(to: contents.appendingPathComponent(recordPath(module: engine.module)))
    }

    /// The folders `path` is in: `a/b` and `a` of `a/b/c`.
    static func folders(above path: String) -> [String] {
        var folders: [String] = []
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            folders.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        return folders
    }

    /// Clone `source` (a file, a link or a whole folder) to `destination`,
    /// or copy it where it can't be cloned.
    static func place(_ source: URL, at destination: URL) throws {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// The engines the wrapp's `contents` holds.
    public static func installed(in contents: URL) -> [Record] {
        let folder = contents.appendingPathComponent("Resources/engines")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            try? JSONDecoder().decode(Record.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
        }
    }

    /// Take `module`'s engine out of the wrapp's `contents`: every file and
    /// link its list names, then each folder that leaves empty, then its
    /// list and record.
    public static func remove(module: String, from contents: URL) throws {
        let files = FileManager.default
        let list = contents.appendingPathComponent(EngineTree.listPath(module: module))
        let paths = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").map(String.init)
        var folders: Set<String> = []
        for path in paths where path != EngineTree.listPath(module: module) {
            let url = contents.appendingPathComponent(path)
            var info = stat()
            if lstat(url.path, &info) == 0 { try files.removeItem(at: url) }
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty {
                folders.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        // A folder left holding only `_CodeSignature` is empty too: an engine
        // is signed after its list is made, so a framework's signature isn't
        // in the list, and left behind it would leave half a framework that
        // breaks the wrapp's own signing.
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            let url = contents.appendingPathComponent(folder)
            guard let left = try? files.contentsOfDirectory(atPath: url.path),
                  left.allSatisfy({ $0 == "_CodeSignature" }) else { continue }
            try files.removeItem(at: url)
        }
        try files.removeItem(at: list)
        try? files.removeItem(at: contents.appendingPathComponent(recordPath(module: module)))
    }
}
