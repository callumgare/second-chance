//
//  Manifest.swift
//  WrappBuilder
//
//  A program bundle's manifest.yaml, as far as Swift reads it so far.

import Foundation

/// A bundle's `manifest.yaml`: the fields something reads so far. The
/// schema (`Bundles/manifest.schema.json`) has every field, and checks a
/// manifest before it is decoded into this, so this needn't check anything
/// itself, and fields nothing reads yet are left out.
public nonisolated struct Manifest: Decodable, Hashable, Sendable {
    public let format: Int
    /// `<namespace>/<name>`.
    public let id: String
    public let version: Int
    public let title: String
    public let series: String?
    public let seriesOrder: Int?
    public let displayName: String?
    public let formerBundleIds: [String]?
    /// A Wrappfile function the default stages run first.
    public let setup: String?
    public let editions: [Edition]
    /// What is kept outside the app, by name.
    public let volumes: [String: Volume]?
    /// How an old wrapp is brought up to this bundle, in order (`UpdatePlanner`).
    public let updates: [Update]?
    /// How its wrapps are tested (`ProgramTest`).
    public let tests: Tests?

    public struct Tests: Decodable, Hashable, Sendable {
        /// `<module>/<scenario>`.
        public let scenario: String?
        public let parameters: [String: TestValue]?
    }

    /// A number, flag or text, kept as text for `${…}`.
    public struct TestValue: Decodable, Hashable, Sendable {
        public let text: String

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                text = flag ? "true" : "false"
            } else if let number = try? container.decode(Double.self) {
                text = number == number.rounded() ? String(Int(number)) : String(number)
            } else {
                text = try container.decode(String.self)
            }
        }
    }

    public struct Volume: Decodable, Hashable, Sendable {
        /// When the volume holds something of the person's: any file in it
        /// (nil, or `any-file`), never, or a file matching one of these.
        public let inUseWhen: InUseWhen?
        public let displayName: String?
    }

    public enum InUseWhen: Decodable, Hashable, Sendable {
        case anyFile, never
        case patterns([String])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let patterns = try? container.decode([String].self) {
                self = .patterns(patterns)
            } else {
                self = try container.decode(String.self) == "never" ? .never : .anyFile
            }
        }
    }

    /// The part of the id after the namespace: today's game slug.
    public var name: String { String(id.split(separator: "/").last ?? "") }
    public var namespace: String { String(id.split(separator: "/").first ?? "") }

    /// The Wrappfile stage built (`target`), the stage it starts from on a
    /// fresh build (`base`), and what the Wrappfile's `INPUT`s are given, by
    /// name. An edition with no stage yet has inputs and no target.
    public struct Build: Decodable, Hashable, Sendable {
        public let target: String?
        public let base: String?
        /// Keyed by name in the manifest; each with its name as its `id`
        /// here, sorted, as a key's case and hyphens wouldn't survive
        /// decoding (`Manifest.decode`).
        public let inputs: [Input]?
    }

    public struct Edition: Decodable, Hashable, Sendable {
        public let id: String
        public let source: Source
        public let detect: Detect?
        public let build: Build?
        /// A download edition's: what the person is told about where it
        /// comes from (`free-release`, …), and who gives the permission.
        public let licence: Licence?
        public let licenceFrom: String?
        /// The licence's own words: a file in the unpacked input.
        public let licenceFile: String?

        /// Its inputs but its choices, sorted by name, each with its name as
        /// its `id` (`disc-1`, `disc-2`).
        public var inputs: [Input]? {
            let given = (build?.inputs ?? []).filter { $0.type != .choice }
            return given.isEmpty ? nil : given
        }

        /// Its choices, by name as written (`launch-mode`).
        public var choices: [String: Choice]? {
            let found = (build?.inputs ?? []).compactMap { input -> (String, Choice)? in
                guard input.type == .choice, let options = input.options, let fallback = input.default else { return nil }
                return (input.id, Choice(options: options, default: fallback, prompt: input.prompt))
            }
            return found.isEmpty ? nil : Dictionary(uniqueKeysWithValues: found)
        }

        /// The choice called `name` (`launch-mode`).
        public func choice(_ name: String) -> Choice? { choices?[name] }

        /// The input called `name`, a choice or not.
        public func input(_ name: String) -> Input? {
            build?.inputs?.first { $0.id == name }
        }
    }

    /// Why a download edition may be offered, which decides what the
    /// person is told before it downloads (docs/program-bundles.md#download-editions).
    public enum Licence: String, Decodable, Hashable, Sendable {
        case freewareLicensed = "freeware-licensed"
        case freeRelease = "free-release"
        case shareware
        case abandonware
    }

    public struct Choice: Decodable, Hashable, Sendable {
        public let options: [String]
        public let `default`: String
        public var prompt: String?
    }

    public enum Source: String, Decodable, Hashable, Sendable {
        case disc
        case herDownload = "her-download"
        case steam
        case bigFish = "big-fish"
        case download
    }

    /// One input; which fields it has depends on its type.
    public struct Input: Decodable, Hashable, Sendable {
        /// Its name in the edition's `build.inputs`.
        public let id: String
        public let type: InputType
        public let format: String?
        public let appId: Int?
        public let commonFolder: String?
        /// A Big Fish edition's product number.
        public let product: Int?
        /// A download's: its URLs in order, its file's SHA-256 and size,
        /// and how it is unpacked (`none`, `zip`) and installed (`none`).
        public let urls: [String]?
        public let sha256: String?
        public let size: Int?
        public let unpack: String?
        public let install: String?
        /// A choice's: its answers, the one taken unasked, and the question.
        public let options: [String]?
        public let `default`: String?
        public let prompt: String?

        /// Its fields as `${input.<name>.<field>}` reads them.
        public var fields: [String: String] {
            var fields = ["id": id, "type": type.rawValue]
            fields["format"] = format
            fields["app-id"] = appId.map(String.init)
            fields["common-folder"] = commonFolder
            fields["product"] = product.map(String.init)
            fields["sha256"] = sha256
            return fields
        }
    }

    /// How the person gives an input.
    public enum InputType: String, Decodable, Hashable, Sendable {
        case disc
        case herDownload = "her-download"
        case steamGame = "steam-game"
        case bigFishGame = "big-fish-game"
        case download
        case choice
    }

    /// How an edition is recognised (`Detection/`): its aliases and codes
    /// join the title in the default matcher; `matchers` are what titles
    /// can't tell apart.
    public struct Detect: Decodable, Hashable, Sendable {
        public let aliases: [String]?
        public let codes: [String]?
        public let matchers: [Matcher]?
    }
}

nonisolated extension Manifest {
    /// Decodes JSON-shaped values a schema has checked, with the manifest's
    /// kebab-case keys (`display-name`) as Swift's camel case.
    static func decode(_ document: Any) throws -> Manifest {
        try decodeKebab(Manifest.self, from: namingInputs(document))
    }

    /// Each edition's `build.inputs`, a mapping by name, as a list of the
    /// inputs with their names as `id`s, sorted: decoding would turn a key
    /// into camel case, which loses `disc-1`'s hyphen.
    static func namingInputs(_ document: Any) -> Any {
        guard var manifest = document as? [String: Any], let editions = manifest["editions"] as? [Any] else { return document }
        manifest["editions"] = editions.map { item -> Any in
            guard var edition = item as? [String: Any], var build = edition["build"] as? [String: Any],
                  let inputs = build["inputs"] as? [String: Any] else { return item }
            build["inputs"] = inputs.keys.sorted().map { name -> Any in
                var input = inputs[name] as? [String: Any] ?? [:]
                input["id"] = name
                return input
            }
            edition["build"] = build
            return edition
        }
        return manifest
    }

    /// Decodes JSON-shaped values into `T`, with kebab-case keys as camel
    /// case: how every YAML file a bundle or module has is read.
    static func decodeKebab<T: Decodable>(_ type: T.Type, from document: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.fragmentsAllowed])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last?.stringValue ?? ""
            let parts = key.split(separator: "-")
            let camel = (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            return KebabKey(camel)
        }
        return try decoder.decode(T.self, from: data)
    }

    private struct KebabKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
