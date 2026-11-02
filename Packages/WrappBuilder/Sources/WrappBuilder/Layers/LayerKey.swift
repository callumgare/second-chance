//
//  LayerKey.swift
//  WrappBuilder
//
//  What a cached layer is made from, and the hash that names it.

import CryptoKit
import Foundation

/// What a layer was made from: its parent's key, the steps it ran, and every
/// input those steps read — module releases and the files they used, the
/// bundle's files, the choices, the disc — each by name, in order. Inputs,
/// never outputs: what Wine writes isn't the same twice.
///
/// The layer store keeps the inputs beside each layer, not only the hash,
/// so a miss can say which input changed (`differences(from:)`).
public nonisolated struct LayerKey: Codable, Sendable, Equatable {
    /// Which layer of a build this is, the same whatever its inputs:
    /// `wine prefix`, `nancy-drew/old-clock cd: install`. A miss is
    /// explained against the last layer stored for the same slot.
    public let slot: String
    public let inputs: [Input]

    public struct Input: Codable, Sendable, Equatable {
        public let name: String
        public let value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// A key for `slot` from `inputs`, chained to `parent`'s (whose hash
    /// comes first), so a changed parent changes every layer on top of it.
    public init(slot: String, parent: LayerKey? = nil, inputs: [Input]) {
        self.slot = slot
        self.inputs = (parent.map { [Input("parent", $0.hash)] } ?? []) + inputs
    }

    /// The key's name in the store: a SHA-256 of the slot and inputs.
    public var hash: String {
        var hasher = SHA256()
        hasher.update(data: Data("slot\0\(slot)\0".utf8))
        for input in inputs {
            hasher.update(data: Data("\(input.name)\0\(input.value)\0".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What changed from `other`, in words: `` `assets/disc.iss` changed ``,
    /// `` `choice launch-mode` added ``. Empty when they're the same.
    public func differences(from other: LayerKey) -> [String] {
        let before = Dictionary(other.inputs.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(inputs.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        var changes: [String] = []
        for input in inputs {
            switch before[input.name] {
            case nil: changes.append("`\(input.name)` added")
            case input.value: break
            case let old?:
                // Short values say what they were; a hash is only "changed".
                let shown = old.count <= 40 && input.value.count <= 40 ? " (\(old) → \(input.value))" : ""
                changes.append("`\(input.name)` changed\(shown)")
            }
        }
        for input in other.inputs where after[input.name] == nil {
            changes.append("`\(input.name)` removed")
        }
        return changes
    }

    // MARK: - Identities of what a layer reads

    /// A file's contents, as a SHA-256.
    public static func hash(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A folder's every file, by path and contents: for module data and
    /// bundle assets, which are small.
    public static func hash(folder: URL) throws -> String {
        try digest(of: folder) { file in try hash(file: file) }
    }

    /// A folder's every path and size, not its contents: a disc's identity,
    /// read in under a second where hashing its gigabytes would take
    /// minutes, and the same for a real disc, an image's mount or a copy.
    public static func listing(of folder: URL) throws -> String {
        try digest(of: folder) { file in
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return String(size)
        }
    }

    private static func digest(of folder: URL, describe: (URL) throws -> String) throws -> String {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walk = FileManager.default.enumerator(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        var entries: [(String, String)] = []
        for case let file as URL in walk {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            // macOS's own litter on a copied disc isn't the disc.
            guard relative != ".DS_Store", !relative.hasSuffix("/.DS_Store") else { continue }
            entries.append((relative, try describe(file)))
        }
        var hasher = SHA256()
        for (path, description) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data("\(path)\0\(description)\0".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
