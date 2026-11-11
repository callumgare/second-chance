//
//  InstalledSign.swift
//  WrappBuilder
//
//  What a folder holding a program already installed has: a manifest's
//  `installed` signs. docs/program-bundles.md#installed-copies has the rules.

import Foundation

/// One of a manifest's `installed` signs: a file matcher, or several that
/// must all match. Any one sign says a folder is the program already
/// installed rather than what installs it.
public nonisolated enum InstalledSign: Hashable, Sendable {
    case matcher(Matcher)
    case allOf([Matcher])

    /// Its matchers: one, or each of an `all-of`.
    public var matchers: [Matcher] {
        switch self {
        case .matcher(let matcher): [matcher]
        case .allOf(let matchers): matchers
        }
    }

    /// How specific a match by it is: its matchers' lengths added up, and
    /// exact if any is a hash, so `all-of` Game.exe and Nancy.cid beats
    /// Game.exe alone.
    public var specificity: Specificity {
        let each = matchers.map(\.specificity)
        return Specificity(exact: each.contains(where: \.exact), length: each.map(\.length).reduce(0, +))
    }

    /// What it is, for a log.
    public var description: String {
        switch self {
        case .matcher(let matcher): matcher.description
        case .allOf(let matchers): "all of " + matchers.map(\.description).joined(separator: ", ")
        }
    }

    /// Whether it could match a folder holding `paths` (from its top, with
    /// forward slashes; a folder's may end in `/`), from their names alone:
    /// a matcher that reads a file is taken to match when the file is
    /// there. How a layout (`Manifest.Layout`) is checked against it.
    public func couldMatch(paths: [String]) -> Bool {
        let names = paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return matchers.allSatisfy { matcher in
            guard let glob = matcher.file else { return false }
            return names.contains { SourceFiles.glob(glob, matches: $0) }
        }
    }
}

// MARK: - Reading a manifest's signs

nonisolated extension InstalledSign: Decodable {
    private enum Keys: String, CodingKey {
        case allOf
    }

    /// An object with `all-of` is several matchers; any other is one
    /// matcher (the schema says which kinds).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.allOf) {
            self = .allOf(try container.decode([Matcher].self, forKey: .allOf))
        } else {
            self = .matcher(try Matcher(from: decoder))
        }
    }
}
