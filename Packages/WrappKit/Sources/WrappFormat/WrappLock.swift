//
//  WrappLock.swift
//  WrappFormat
//
//  What a wrapp was built from, recorded in it.

import Foundation
import WrappModules

/// What a wrapp was built from: its bundle and that bundle's version, the
/// edition, the modules and the release of each, and the Second Chance that
/// built it (`Contents/Resources/WrappLock.json`). Updating a wrapp works
/// out what to do from it; logs and reports say it. A wrapp built before
/// locks has none, and one is made up for it from its settings when needed.
nonisolated public struct WrappLock: Codable, Sendable, Equatable {
    /// A newer format than this reads is read as far as it can be.
    public var format: Int = 1
    public var bundle: BundleRef
    public var edition: String
    /// Where the edition came from: `disk`, `her-download`, `steam`.
    public var source: String
    public var composition: Composition
    public var modules: [ModuleRef]
    /// The version of Second Chance that built it.
    public var builtBy: String
    public var builtAt: Date

    public struct BundleRef: Codable, Sendable, Equatable {
        /// `nancy-drew/blue-moon`.
        public var id: String
        public var version: Int

        public init(id: String, version: Int) {
            self.id = id
            self.version = version
        }
    }

    public struct ModuleRef: Codable, Sendable, Equatable {
        public var id: String
        public var release: Int
        /// The version the build used, as `USE` resolved it.
        public var version: String?

        public init(id: String, release: Int, version: String?) {
            self.id = id
            self.release = release
            self.version = version
        }
    }

    public init(bundle: BundleRef, edition: String, source: String, composition: Composition,
                modules: [ModuleRef], builtBy: String, builtAt: Date = Date()) {
        self.bundle = bundle
        self.edition = edition
        self.source = source
        self.composition = composition
        self.modules = modules
        self.builtBy = builtBy
        self.builtAt = builtAt
    }

    /// The lock of the wrapp at `layout`; nil for a wrapp built before locks.
    public init?(of layout: WrappLayout) throws {
        guard FileManager.default.fileExists(atPath: layout.lockFile.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Self.self, from: Data(contentsOf: layout.lockFile))
    }

    public func write(to layout: WrappLayout) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: layout.resources, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: layout.lockFile)
    }

    /// For logs: "nancy-drew/blue-moon 1 (cd), wine 10.0_8 (release 1), …".
    public var summary: String {
        "\(bundle.id) \(bundle.version) (\(edition)), "
            + modules.map { "\($0.id)\($0.version.map { " \($0)" } ?? "") (release \($0.release))" }.joined(separator: ", ")
    }
}
