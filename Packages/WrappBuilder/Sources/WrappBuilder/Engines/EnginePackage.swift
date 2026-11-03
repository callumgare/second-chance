//
//  EnginePackage.swift
//  WrappBuilder
//
//  What an engine version is made from: its makers' downloads, and the
//  hash of the tree preparing them gives.

import Foundation

/// An engine version's package (`versions[].package` in its `module.yaml`):
/// the downloads it is made from, each checked by its SHA-256, and the hash
/// of the tree that preparing them must give (`EngineTree`), so every Mac
/// runs what was tested (docs/modules.md#engine-packages).
public nonisolated struct EnginePackage: Decodable, Hashable, Sendable {
    /// `EngineTree.hash` of the prepared tree; nil while a version is being
    /// made, before its hash is known.
    public let prepared: String?
    public let sources: [Source]
    /// ScummVM's: the engine data files kept from its app's Resources, one
    /// for each engine a shipped bundle's game uses (`nancy.dat`).
    public let engineData: [String]?

    /// One download, by the id the module's preparing knows it as.
    public struct Source: Decodable, Hashable, Sendable {
        public let id: String
        public let sha256: String
        public let size: Int64?
        public let urls: [String]

        public var request: DownloadRequest {
            DownloadRequest(urls: urls.compactMap(URL.init(string:)), sha256: sha256, size: size)
        }
    }

    public func source(_ id: String) throws -> Source {
        guard let source = sources.first(where: { $0.id == id }) else {
            throw EngineError("the package has no source \(id)")
        }
        return source
    }
}

public nonisolated struct EngineError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

nonisolated extension ModuleManifest {
    /// The package of `version`, or of the newest version with one when
    /// nil; nil when the module has no engine to prepare.
    public func package(version: String? = nil) -> (version: String, package: EnginePackage)? {
        let candidates = versions.filter { $0.withdrawn != true && $0.package != nil }
        let chosen = version.map { wanted in candidates.first { $0.version == wanted } } ?? candidates.first
        guard let chosen, let package = chosen.package else { return nil }
        return (chosen.version, package)
    }
}
