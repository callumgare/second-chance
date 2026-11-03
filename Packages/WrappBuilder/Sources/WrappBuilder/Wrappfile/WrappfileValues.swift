//
//  WrappfileValues.swift
//  WrappBuilder
//
//  What a `${…}` names, and the values it can have.

import Foundation

/// What's between `${` and `}`: a namespace and a path into it, with
/// brackets for a key worked out from another value
/// (`self.data.patches[input.id].url`). No modifiers, and no `${…}` inside
/// another: brackets replace that.
public nonisolated struct Reference: Sendable, Equatable, CustomStringConvertible {
    public let segments: [Segment]

    public indirect enum Segment: Sendable, Equatable {
        /// `.name`
        case name(String)
        /// `[reference]`: a key worked out from another value.
        case key(Reference)
    }

    /// The namespaces the core has: a module whose name is one of these is
    /// reached through `module.<name>`.
    public static let coreNamespaces: Set<String> = ["input", "const", "var", "platform", "module", "self", "program"]

    /// The first name: its namespace, or a module's name.
    public var root: String {
        if case .name(let name) = segments.first { return name }
        return ""
    }

    /// The names after the root, up to the first bracket.
    public var plainPath: [String] {
        var names: [String] = []
        for segment in segments.dropFirst() {
            guard case .name(let name) = segment else { break }
            names.append(name)
        }
        return names
    }

    public var description: String {
        segments.enumerated().map { index, segment in
            switch segment {
            case .name(let name): index == 0 ? name : ".\(name)"
            case .key(let inner): "[\(inner)]"
            }
        }.joined()
    }

    /// Every reference in it, those in brackets included.
    public var all: [Reference] {
        [self] + segments.flatMap { segment -> [Reference] in
            if case .key(let inner) = segment { return inner.all }
            return []
        }
    }

    /// `text` as a reference, or why it isn't one.
    public static func parse(_ text: String) throws(WrappfileError) -> Reference {
        var characters = Array(text)[...]
        let reference = try parse(&characters, whole: text)
        guard characters.isEmpty else {
            throw WrappfileError(line: 0, message: "${\(text)}: \(String(characters)) isn't part of a reference")
        }
        return reference
    }

    private static func parse(_ characters: inout ArraySlice<Character>, whole: String) throws(WrappfileError) -> Reference {
        if whole.contains(":-") {
            throw WrappfileError(line: 0, message: "${\(whole)}: modifiers such as :- are gone; a module's data schema gives an optional field its default")
        }
        if whole.contains("${") {
            throw WrappfileError(line: 0, message: "${\(whole)}: a ${…} can't hold another; write a key worked out from a value in brackets: ${self.data.patches[input.id].url}")
        }
        var segments: [Segment] = []
        var expectName = true
        while let next = characters.first {
            if next == "]" { break }
            if next == "[" {
                characters.removeFirst()
                let inner = try parse(&characters, whole: whole)
                guard characters.first == "]" else {
                    throw WrappfileError(line: 0, message: "${\(whole)}: a [ isn't closed")
                }
                characters.removeFirst()
                segments.append(.key(inner))
                expectName = false
                continue
            }
            if next == "." {
                guard !segments.isEmpty, !expectName else {
                    throw WrappfileError(line: 0, message: "${\(whole)}: a name is missing around a .")
                }
                characters.removeFirst()
                expectName = true
                continue
            }
            guard expectName else {
                throw WrappfileError(line: 0, message: "${\(whole)}: names are separated by .")
            }
            var name = ""
            while let character = characters.first, character.isLetter || character.isNumber || character == "-" || character == "_" {
                name.append(character)
                characters.removeFirst()
            }
            guard !name.isEmpty else {
                throw WrappfileError(line: 0, message: "${\(whole)}: \(next) can't be in a name")
            }
            segments.append(.name(name))
            expectName = false
        }
        guard !segments.isEmpty, !expectName, case .name = segments[0] else {
            throw WrappfileError(line: 0, message: "${\(whole)} names nothing")
        }
        return Reference(segments: segments)
    }
}

/// A value a `${…}` reads: text, or an object (a data table's entry, an
/// input with its fields). Numbers and true/false are text for now.
public nonisolated indirect enum WrappValue: Sendable, Equatable {
    case text(String)
    case object([String: WrappValue])
    case list([WrappValue])

    /// Values decoded from JSON or YAML.
    public init(_ any: Any) {
        switch any {
        case let text as String: self = .text(text)
        case let flag as Bool: self = .text(flag ? "true" : "false")
        case let number as Int: self = .text(String(number))
        case let number as Double: self = .text(number == number.rounded() ? String(Int(number)) : String(number))
        case let object as [String: Any]: self = .object(object.mapValues(WrappValue.init))
        case let list as [Any]: self = .list(list.map(WrappValue.init))
        default: self = .text("\(any)")
        }
    }

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// The value under `key`: an object's property, or in a list (or an
    /// object that is one list under a single key, as `patches.json` is),
    /// the item whose `id` is `key`.
    public func member(_ key: String) -> WrappValue? {
        switch self {
        case .object(let object):
            if let value = object[key] { return value }
            let lists = object.values.filter { if case .list = $0 { true } else { false } }
            return lists.count == 1 ? lists[0].member(key) : nil
        case .list(let items):
            return items.first { $0.member("id") == .text(key) }
        case .text:
            return nil
        }
    }
}

/// A module's data tables with their schemas' defaults filled in, so a
/// field a schema gives a `default` always has a value.
nonisolated enum SchemaDefaults {
    /// `value` with every missing property its schema gives a default to
    /// added: through `properties`, `items`, `additionalProperties` and
    /// `$ref`s into `$defs`.
    static func fill(_ value: Any, schema: [String: Any], root: [String: Any]) -> Any {
        var schema = schema
        if let ref = schema["$ref"] as? String, ref.hasPrefix("#/$defs/"),
           let defs = root["$defs"] as? [String: Any], let target = defs[String(ref.dropFirst("#/$defs/".count))] as? [String: Any] {
            schema = target.merging(schema.filter { $0.key != "$ref" }) { $1 }
        }
        if var object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, child) in properties {
                guard let child = child as? [String: Any] else { continue }
                if let existing = object[key] {
                    object[key] = fill(existing, schema: child, root: root)
                } else if let fallback = child["default"] {
                    object[key] = fallback
                }
            }
            if let additional = schema["additionalProperties"] as? [String: Any] {
                for (key, existing) in object where properties[key] == nil {
                    object[key] = fill(existing, schema: additional, root: root)
                }
            }
            return object
        }
        if let list = value as? [Any], let items = schema["items"] as? [String: Any] {
            return list.map { fill($0, schema: items, root: root) }
        }
        return value
    }
}
