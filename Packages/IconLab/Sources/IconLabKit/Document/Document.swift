import Foundation

// The icon document (docs/document.md). Codable for rendering; the store keeps each document's JSON as sent, so
// keys this engine doesn't know survive.

nonisolated public struct Doc: Codable, Sendable {
    public var schema: Int = 1
    public var id: String
    public var parent: String?
    public var name: String
    public var program: String
    public var origin: Origin?
    public var fill: Fill
    public var groups: [Group]
    public var created: String

    public init(id: String = UUID().uuidString.lowercased(), parent: String? = nil, name: String, program: String,
                origin: Origin? = nil, fill: Fill, groups: [Group]) {
        self.id = id; self.parent = parent; self.name = name; self.program = program; self.origin = origin
        self.fill = fill; self.groups = groups
        created = ISO8601DateFormatter().string(from: Date())
    }
}

nonisolated public struct Origin: Codable, Sendable {
    public var treatment: String
    public var params: SuggestionParams
}

nonisolated public struct Fill: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case gradient, solid, none }
    public var kind: Kind
    public var color: RGB
    public var dark: RGB?
    public init(kind: Kind, color: RGB, dark: RGB? = nil) { self.kind = kind; self.color = color; self.dark = dark }
    public static let none = Fill(kind: .none, color: RGB(0, 0, 0))
}

nonisolated public struct Group: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var hidden: Bool?
    public var glass: Glass
    public var layers: [Layer]
    public init(id: String = UUID().uuidString.lowercased(), name: String, glass: Glass = .init(), layers: [Layer]) {
        self.id = id; self.name = name; self.glass = glass; self.layers = layers
    }
}

nonisolated public struct Glass: Codable, Sendable, Hashable {
    public var specular: Bool = true
    public var shadow: Double = 0.35
    public var translucency: Double?
    public var blur: Double?
    /// Icon Composer's Liquid Glass mode: "individual" (each layer its own glass) or "combined" (the group as one).
    public var lighting: String?
    /// "none", "neutral" or "chromatic" (Icon Composer's layer-colour shadow); nil: neutral when `shadow` > 0.
    public var shadowKind: String?
    public var shadowKindResolved: String { shadowKind ?? (shadow > 0 ? "neutral" : "none") }
    public init(specular: Bool = true, shadow: Double = 0.35, translucency: Double? = nil, blur: Double? = nil) {
        self.specular = specular; self.shadow = shadow; self.translucency = translucency; self.blur = blur
    }
}

nonisolated public struct Layer: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var role: String?
    public var hidden: Bool?
    public var opacity: Double
    public var content: Content
    public var transform: Transform
    public var mask: Mask?
    public init(id: String = UUID().uuidString.lowercased(), name: String, role: String? = nil, opacity: Double = 1,
                content: Content, transform: Transform = .full, mask: Mask? = nil) {
        self.id = id; self.name = name; self.role = role; self.opacity = opacity
        self.content = content; self.transform = transform; self.mask = mask
    }
}

nonisolated public struct Transform: Codable, Sendable, Hashable {
    public var x: Double, y: Double, width: Double, rotation: Double
    public init(x: Double, y: Double, width: Double, rotation: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.rotation = rotation
    }
    public static let full = Transform(x: 0.5, y: 0.5, width: 1)
}

nonisolated public enum Content: Codable, Sendable, Hashable {
    case image(ImageContent)
    case shape(Shape)

    enum Key: String, CodingKey { case kind, shape }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "image": self = .image(try ImageContent(from: decoder))
        case "shape": self = .shape(try c.decode(Shape.self, forKey: .shape))
        case let k: throw IconLabError.invalid("content kind \(k)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .image(let i):
            try i.encode(to: encoder)
            var c = encoder.container(keyedBy: Key.self)
            try c.encode("image", forKey: .kind)
        case .shape(let s):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode("shape", forKey: .kind)
            try c.encode(s, forKey: .shape)
        }
    }
}

nonisolated public struct ImageContent: Codable, Sendable, Hashable {
    public var asset: String
    public var cutout: Bool
    public var crop: [Double]?
    public var smoothing: String = "smooth"
    public var effects: [Effect] = []
    public init(asset: String, cutout: Bool, crop: [Double]? = nil, smoothing: String = "smooth", effects: [Effect] = []) {
        self.asset = asset; self.cutout = cutout; self.crop = crop; self.smoothing = smoothing; self.effects = effects
    }
}

/// Shapes and effects are kept as tagged dictionaries of loosely typed values: the set grows often, and the UI
/// edits their parameters generically. Accessors read them with defaults.
nonisolated public struct Tagged: Codable, Sendable, Hashable {
    public var tag: String
    public var values: [String: JSONValue]

    public init(_ tag: String, _ values: [String: JSONValue] = [:]) { self.tag = tag; self.values = values }

    public func string(_ k: String, _ d: String = "") -> String { values[k]?.stringValue ?? d }
    public func double(_ k: String, _ d: Double = 0) -> Double { values[k]?.doubleValue ?? d }
    public func bool(_ k: String, _ d: Bool = false) -> Bool { values[k]?.boolValue ?? d }
    public func colour(_ k: String, _ d: RGB = RGB(0, 0, 0)) -> RGB { values[k]?.stringValue.flatMap(RGB.init(hex:)) ?? d }
    public func doubles(_ k: String) -> [Double] { values[k]?.arrayValue?.compactMap(\.doubleValue) ?? [] }
    public func colours(_ k: String) -> [RGB] { values[k]?.arrayValue?.compactMap { $0.stringValue.flatMap(RGB.init(hex:)) } ?? [] }
}

/// A shape: `{ "type": "pattern", ... }`.
nonisolated public struct Shape: Codable, Sendable, Hashable {
    public var t: Tagged
    public init(_ type: String, _ values: [String: JSONValue] = [:]) { t = Tagged(type, values) }
    public var type: String { t.tag }
    public init(from decoder: Decoder) throws { t = try Tagged.decode(from: decoder, tagKey: "type") }
    public func encode(to encoder: Encoder) throws { try t.encode(to: encoder, tagKey: "type") }
}

/// An effect: `{ "op": "halftone", ... }`.
nonisolated public struct Effect: Codable, Sendable, Hashable {
    public var t: Tagged
    public init(_ op: String, _ values: [String: JSONValue] = [:]) { t = Tagged(op, values) }
    public var op: String { t.tag }
    /// Whether it's applied: an effect turned off (`"off": true`) stays in the list, doing nothing.
    public var on: Bool { !t.bool("off") }
    public init(from decoder: Decoder) throws { t = try Tagged.decode(from: decoder, tagKey: "op") }
    public func encode(to encoder: Encoder) throws { try t.encode(to: encoder, tagKey: "op") }
}

/// A mask: `{ "kind": "ring", ... }`; shape and image masks carry a nested shape / transform.
nonisolated public struct Mask: Codable, Sendable, Hashable {
    public var t: Tagged
    public init(_ kind: String, _ values: [String: JSONValue] = [:]) { t = Tagged(kind, values) }
    public var kind: String { t.tag }
    public init(from decoder: Decoder) throws { t = try Tagged.decode(from: decoder, tagKey: "kind") }
    public func encode(to encoder: Encoder) throws { try t.encode(to: encoder, tagKey: "kind") }

    public var shape: Shape? { t.values["shape"].flatMap { try? $0.decode(Shape.self) } }
    public var transform: Transform? { t.values["transform"].flatMap { try? $0.decode(Transform.self) } }
}

nonisolated extension Tagged {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func decode(from decoder: Decoder, tagKey: String) throws -> Tagged {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var values: [String: JSONValue] = [:]
        var tag = ""
        for key in c.allKeys {
            if key.stringValue == tagKey { tag = try c.decode(String.self, forKey: key) } else {
                values[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
            }
        }
        return Tagged(tag, values)
    }

    func encode(to encoder: Encoder, tagKey: String) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(tag, forKey: AnyKey(tagKey))
        for (k, v) in values { try c.encode(v, forKey: AnyKey(k)) }
    }
}

/// Any JSON value.
nonisolated public enum JSONValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) { self = .string(s) } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
    }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

nonisolated extension RGB {
    public var json: JSONValue { .string(hex) }
}

nonisolated public struct SuggestionParams: Codable, Sendable, Hashable {
    public var primary: String?
    public var secondary: String?
    public var background: String?
    public var scale: Double?
    public var dx: Double?
    public var dy: Double?
    public var logoScale: Double?
    public var dx2: Double?
    public var dy2: Double?
    public var angle: Double?
    public var pattern: String?
    public var cell: Double?
    public var offset: Double?
    public var letter: String?
    public var snap: Bool?
    public var roles: [String: String]?
    public init() {}
}
