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
    public let variants: [Variant]?
    public let editions: [Edition]

    /// The part of the id after the namespace: today's game slug.
    public var name: String { String(id.split(separator: "/").last ?? "") }
    public var namespace: String { String(id.split(separator: "/").first ?? "") }

    public struct Variant: Decodable, Hashable, Sendable {
        public let id: String
        public let build: Build?
        public let launch: Launch?
    }

    /// The Wrappfile stage built (`target`), and the stage it starts from
    /// on a fresh build (`base`).
    public struct Build: Decodable, Hashable, Sendable {
        public let target: String
        public let base: String?
    }

    public struct Launch: Decodable, Hashable, Sendable {
        public let wine: WineLaunch?
    }

    public struct WineLaunch: Decodable, Hashable, Sendable {
        public let exe: String?
        /// What it draws with, `direct-draw` or `direct-3d`.
        public let graphics: String?
    }

    public struct Edition: Decodable, Hashable, Sendable {
        public let id: String
        public let source: Source
        public let inputs: [Input]?
        public let detect: Detect?
        public let installer: Installer?
        public let drm: String?
        public let build: Build?
        /// Its choices, by name: each an `ARG` its stages may read.
        public let choices: [String: Choice]?
    }

    public struct Choice: Decodable, Hashable, Sendable {
        public let options: [String]
        public let `default`: String
    }

    public enum Source: String, Decodable, Hashable, Sendable {
        case disc
        case herDownload = "her-download"
        case steam
        case bigFish = "big-fish"
        case download
    }

    /// One input; which fields it has depends on the edition's source.
    public struct Input: Decodable, Hashable, Sendable {
        public let id: String
        public let format: String?
        public let appId: Int?
        public let commonFolder: String?
        public let exe: String?
        /// A Big Fish edition's product number.
        public let product: Int?
    }

    public struct Detect: Decodable, Hashable, Sendable {
        public let aliases: [String]?
        public let codes: [String]?
    }

    public struct Installer: Decodable, Hashable, Sendable {
        public let stubborn: Bool?
    }
}

nonisolated extension Manifest {
    /// Decodes JSON-shaped values a schema has checked, with the manifest's
    /// kebab-case keys (`display-name`) as Swift's camel case.
    static func decode(_ document: Any) throws -> Manifest {
        try decodeKebab(Manifest.self, from: document)
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
