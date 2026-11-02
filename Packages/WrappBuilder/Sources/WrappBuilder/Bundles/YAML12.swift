//
//  YAML12.swift
//  WrappBuilder
//
//  Reads YAML as YAML 1.2 does, into the JSON a schema checks.

import Foundation
import Yams

/// Reads a bundle's YAML the way YAML 1.2, and so the editor's YAML
/// extension, reads it, into JSON-shaped values.
///
/// Yams parses with libyaml, which reads both YAML versions' syntax alike;
/// what differs is how a plain value's type is decided, which Yams takes
/// from a `Resolver`. Its default is YAML 1.1's, where a bare `no`, `off`
/// or `yes` is a boolean, so this one is YAML 1.2's core schema: only
/// `true` and `false` are booleans, `null`, `~` and nothing are null, and
/// numbers are written as YAML 1.2 writes them. Quoted values are always
/// strings. A bundle is checked from these values, never only by decoding
/// it into Swift types, which read a bare `no` as the text written and drop
/// a mistyped key without a word.
nonisolated enum YAML12 {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    /// YAML 1.2's core schema, as regular expressions over a plain value;
    /// anything else plain is text.
    static func resolver() throws -> Resolver {
        try Resolver.basic
            .appending(.null, "^(?:~|null|Null|NULL|)$")
            .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
            .appending(.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$")
            .appending(.float, "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$")
    }

    /// The document in `text` as JSON-shaped values (`[String: Any]`,
    /// `[Any]`, `String`, `Int`, `Double`, `Bool`, `NSNull`).
    static func load(_ text: String) throws -> Any {
        let resolver = try resolver()
        let node: Node?
        do {
            node = try Yams.compose(yaml: text, resolver)
        } catch {
            throw Error(description: "isn't valid YAML: \(error)")
        }
        guard let node else { return NSNull() }
        return try value(of: node, at: "")
    }

    private static func value(of node: Node, at path: String) throws -> Any {
        switch node {
        case .scalar(let scalar):
            return try value(of: scalar, tag: node.tag, at: path)
        case .sequence(let sequence):
            return try sequence.enumerated().map { try value(of: $1, at: "\(path)/\($0)") }
        case .mapping(let mapping):
            var object: [String: Any] = [:]
            for (key, value) in mapping {
                guard case .scalar(let keyScalar) = key, key.tag.description == Tag.Name.str.rawValue else {
                    throw Error(description: "at \(path.isEmpty ? "/" : path): \(key.any) is a key that isn't text; quote it")
                }
                let name = keyScalar.string
                if object[name] != nil {
                    throw Error(description: "at \(path.isEmpty ? "/" : path): \(name) is given twice")
                }
                object[name] = try self.value(of: value, at: "\(path)/\(name)")
            }
            return object
        case .alias:
            // Yams resolves aliases while composing.
            throw Error(description: "at \(path): an alias that wasn't resolved")
        }
    }

    private static func value(of scalar: Node.Scalar, tag: Tag, at path: String) throws -> Any {
        let text = scalar.string
        switch tag.description {
        case Tag.Name.null.rawValue:
            return NSNull()
        case Tag.Name.bool.rawValue:
            return text.lowercased() == "true"
        case Tag.Name.int.rawValue:
            let int: Int?
            if text.hasPrefix("0o") {
                int = Int(text.dropFirst(2), radix: 8)
            } else if text.hasPrefix("0x") {
                int = Int(text.dropFirst(2), radix: 16)
            } else {
                int = Int(text)
            }
            guard let int else { throw Error(description: "at \(path): \(text) is too big a number") }
            return int
        case Tag.Name.float.rawValue:
            switch text.lowercased() {
            case ".inf", "+.inf": return Double.infinity
            case "-.inf": return -Double.infinity
            case ".nan": return Double.nan
            default:
                guard let double = Double(text) else { throw Error(description: "at \(path): \(text) isn't a number") }
                return double
            }
        case Tag.Name.str.rawValue:
            return text
        default:
            throw Error(description: "at \(path): the tag \(tag) isn't one a bundle can use")
        }
    }
}
