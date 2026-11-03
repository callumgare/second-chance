//
//  Update.swift
//  WrappBuilder
//
//  One entry of a manifest's or a module's `updates`.

import Foundation

/// One way of bringing an old wrapp up to this build, as a bundle's
/// manifest or a module lists it: which wrapps it applies to (`from`), the
/// stage it builds (`build`), and what it leaves the program at (`to`).
/// Run like a database's migrations, in order, each starting from the last
/// (docs/wrapp-build.md#updating-a-wrapp).
public nonisolated struct Update: Decodable, Hashable, Sendable {
    public let id: String
    /// What the program must be at for this update to apply; nil applies
    /// to any old wrapp.
    public let from: Requirements?
    /// What it leaves the program at, where that isn't this build's.
    public let to: Requirements?
    /// The stage it builds; nil builds the edition's own target, a fresh
    /// build with `previous` there to take things from.
    public let build: Manifest.Build?
    /// Wrapps it matches can't be brought forward and are built afresh
    /// from their source.
    public let freshBuild: Bool?
    /// A module's default update only: it applies when one of these files
    /// of the module's differs from the ones the old wrapp was built with.
    public let whenChanged: [String]?

    public init(id: String, from: Requirements? = nil, to: Requirements? = nil, build: Manifest.Build? = nil,
                freshBuild: Bool? = nil, whenChanged: [String]? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.build = build
        self.freshBuild = freshBuild
        self.whenChanged = whenChanged
    }

    /// `{ wine: "9", bundle: "<4", nancy-drew: { release: "<3" } }`: the
    /// bundle's version or a module's, each a version, a constraint or, for a
    /// module, its release.
    public struct Requirements: Decodable, Hashable, Sendable {
        public let entries: [String: Requirement]

        public init(_ entries: [String: Requirement]) { self.entries = entries }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            var entries: [String: Requirement] = [:]
            for key in container.allKeys {
                // Keys arrive camel-cased (`nancyDrew`); ids are kebab-case.
                entries[WrappfileChecker.kebabCase(key.stringValue)] = try container.decode(Requirement.self, forKey: key)
            }
            self.entries = entries
        }

        public var bundle: Requirement? { entries["bundle"] }
        public var modules: [String: Requirement] { entries.filter { $0.key != "bundle" } }
    }

    /// A version and a release, each a value or a constraint (`<3`, `10`,
    /// `>=10.0_6`); either may be missing.
    public struct Requirement: Decodable, Hashable, Sendable {
        public let version: String?
        public let release: String?

        public init(version: String? = nil, release: String? = nil) {
            self.version = version
            self.release = release
        }

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer() {
                if let number = try? container.decode(Int.self) {
                    self.init(version: String(number))
                    return
                }
                if let text = try? container.decode(String.self) {
                    self.init(version: text)
                    return
                }
            }
            let container = try decoder.container(keyedBy: AnyKey.self)
            func value(_ key: String) throws -> String? {
                guard let key = AnyKey(stringValue: key), container.contains(key) else { return nil }
                if let number = try? container.decode(Int.self, forKey: key) { return String(number) }
                return try container.decode(String.self, forKey: key)
            }
            self.init(version: try value("version"), release: try value("release"))
        }

        /// Whether a version and release meet this.
        public func holds(version: String?, release: Int?) -> Bool {
            if let constraint = self.version {
                guard let version, WrappfileChecker.matches(version, constraint) else { return false }
            }
            if let constraint = self.release {
                guard let release, WrappfileChecker.matches(String(release), constraint) else { return false }
            }
            return true
        }
    }

    struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
