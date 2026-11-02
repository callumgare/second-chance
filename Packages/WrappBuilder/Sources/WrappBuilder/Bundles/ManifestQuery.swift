//
//  ManifestQuery.swift
//  WrappBuilder
//
//  `sc bundle list --where`: matching a manifest by any field.

import Foundation

/// A condition on a manifest, written as a path into it and a value:
/// `notes.installer=installshield`, `series=Nancy Drew`,
/// `editions.source=steam`. A list along the path matches when any of its
/// items does, so the last means any edition.
public nonisolated struct ManifestQuery: Sendable, Hashable {
    public let path: [String]
    public let value: String

    /// `<path>=<value>`, or nil when there's no `=` or no path.
    public init?(_ text: String) {
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let path = text[..<equals].split(separator: ".").map(String.init)
        guard !path.isEmpty else { return nil }
        self.path = path
        value = String(text[text.index(after: equals)...])
    }

    /// Whether the manifest (as `ProgramBundleLoader.document(in:)` reads
    /// it) has the value at the path.
    public func matches(_ document: Any) -> Bool {
        Self.matches(document, path[...], value)
    }

    private static func matches(_ node: Any, _ path: ArraySlice<String>, _ value: String) -> Bool {
        if let list = node as? [Any] {
            return list.contains { matches($0, path, value) }
        }
        guard let key = path.first else { return text(of: node) == value }
        guard let object = node as? [String: Any], let next = object[key] else { return false }
        return matches(next, path.dropFirst(), value)
    }

    /// A plain value as it would be written unquoted.
    private static func text(of node: Any) -> String? {
        switch node {
        case let text as String: text
        case let flag as Bool: flag ? "true" : "false"
        case let number as Int: String(number)
        case let number as Double: String(number)
        default: nil
        }
    }
}
