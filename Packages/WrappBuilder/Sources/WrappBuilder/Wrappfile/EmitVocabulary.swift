//
//  EmitVocabulary.swift
//  WrappBuilder
//
//  The EMIT strings a caller reads, and what's wrong with a plan's.

import Foundation

/// The strings one caller reads from `EMIT`s, as its own file declares them
/// (Second Chance's `emit-vocabulary.yaml`): the builder passes every
/// `EMIT` on unread, so a caller that wants typos caught declares what it
/// reads, and checks plans against it. A string without the caller's prefix
/// is someone else's and never checked.
public nonisolated struct EmitVocabulary: Sendable, Equatable {
    public let prefix: String
    public let strings: [Pattern]

    /// `second-chance.phase.<phase>`: its literal parts, and each
    /// placeholder's values, a list or `number`.
    public struct Pattern: Sendable, Equatable {
        public let pattern: String
        public let values: [String: Values]
        /// A placeholder whose values are in order, and never go back in a
        /// build (a phase).
        public let ordered: String?

        public enum Values: Sendable, Equatable {
            case oneOf([String])
            case number
        }

        /// The placeholders' values in `string`, if it matches.
        public func match(_ string: String) -> [String: String]? {
            var remaining = Substring(string)
            var found: [String: String] = [:]
            var rest = Substring(pattern)
            while !rest.isEmpty {
                guard let open = rest.firstIndex(of: "<") else {
                    return remaining == rest ? found : nil
                }
                let literal = rest[..<open]
                guard remaining.hasPrefix(literal), let close = rest[open...].firstIndex(of: ">") else { return nil }
                remaining = remaining.dropFirst(literal.count)
                let name = String(rest[rest.index(after: open)..<close])
                rest = rest[rest.index(after: close)...]
                // The value runs to the next literal, or the end.
                let next = rest.prefix { $0 != "<" }
                let value: Substring
                if next.isEmpty {
                    value = remaining
                } else if let at = remaining.range(of: next) {
                    value = remaining[..<at.lowerBound]
                } else {
                    return nil
                }
                guard !value.isEmpty else { return nil }
                switch values[name] {
                case .oneOf(let allowed)? where !allowed.contains(String(value)): return nil
                case .number? where !value.allSatisfy(\.isNumber) && !value.contains("${"): return nil
                default: break
                }
                found[name] = String(value)
                remaining = remaining.dropFirst(value.count)
            }
            return remaining.isEmpty ? found : nil
        }
    }

    public init(prefix: String, strings: [Pattern]) {
        self.prefix = prefix
        self.strings = strings
    }

    /// The vocabulary in `file`: YAML, `prefix` and `strings`, each with a
    /// `pattern`, its placeholders' `values` and what's `ordered`.
    public static func load(_ file: URL) throws -> EmitVocabulary {
        let document = try YAML12.load(String(contentsOf: file, encoding: .utf8)) as? [String: Any] ?? [:]
        let strings = (document["strings"] as? [[String: Any]] ?? []).map { entry in
            Pattern(pattern: entry["pattern"] as? String ?? "",
                    values: (entry["values"] as? [String: Any] ?? [:]).mapValues { value in
                        (value as? String) == "number" ? .number : .oneOf(value as? [String] ?? [])
                    },
                    ordered: entry["ordered"] as? String)
        }
        return EmitVocabulary(prefix: document["prefix"] as? String ?? "", strings: strings)
    }

    /// What's wrong with `plan`'s `EMIT`s, in the order the build reaches
    /// them: a string with the prefix that nothing declares, and an ordered
    /// value that goes back.
    public func problems(in plan: BuildPlan) -> [String] {
        var problems: [String] = []
        var reached: [String: Int] = [:]
        for emit in plan.stages.flatMap(\.emits) where emit.text.hasPrefix(prefix) {
            guard let (pattern, values) = strings.lazy.compactMap({ pattern in pattern.match(emit.text).map { (pattern, $0) } }).first else {
                problems.append("\(emit.origin): EMIT \"\(emit.text)\" isn't one of the \(prefix) strings")
                continue
            }
            guard let ordered = pattern.ordered, case .oneOf(let order)? = pattern.values[ordered],
                  let value = values[ordered], let index = order.firstIndex(of: value) else { continue }
            let key = pattern.pattern
            if let before = reached[key], index < before {
                problems.append("\(emit.origin): EMIT \"\(emit.text)\" goes back to \(value), after \(order[before])")
            }
            reached[key] = max(reached[key] ?? 0, index)
        }
        return problems
    }
}
