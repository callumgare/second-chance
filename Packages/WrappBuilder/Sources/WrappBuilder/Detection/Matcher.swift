//
//  Matcher.swift
//  WrappBuilder
//
//  One way of recognising a program from what a disc or download shows of
//  itself. docs/program-bundles.md has each kind's manifest syntax.

import Foundation

/// One thing that, found in a disc or download, says which program it is.
/// The default matcher every bundle has is its title and aliases (`text`)
/// and its codes (`word`); the rest are written in an edition's
/// `detect.matchers`, for what titles can't tell apart.
public nonisolated enum Matcher: Hashable, Sendable {
    /// Text anywhere in the fingerprint, case aside: a title (without a
    /// leading "The"), an alias.
    case text(String)
    /// A word in the fingerprint, between spaces, case and all: a code
    /// (`STFD`). The riskiest kind, as a volume label can have `SEA` in it,
    /// so it is a kind of its own.
    case word(String)
    /// A file is there.
    case fileExists(file: String)
    /// A file holds this text, exactly as written, in UTF-8 or UTF-16.
    case fileContains(file: String, text: String)
    /// A file's size, and the md5 of its first `bytes` bytes (ScummVM's
    /// AdvancedDetector's tables).
    case fileHash(file: String, size: Int, md5: String, bytes: Int)
    /// A Windows program's version string `key` has this text, case aside.
    case exeVersion(file: String, key: String, text: String)
    /// An MSI's summary information has this text in its subject, case aside.
    case msiSummary(file: String, subject: String)
    /// The disc's volume name, whole, case aside, with `*` and `?`.
    case volumeName(String)

    /// The bytes a `file-hash` matcher hashes when its manifest doesn't say.
    public static let defaultHashBytes = 5000
    /// The MSI an `msi-summary` matcher reads when its manifest doesn't say.
    public static let defaultMSI = "*.msi"

    /// The kind, as the manifest names it and logs and reports give it.
    public var kind: String {
        switch self {
        case .text: "text"
        case .word: "word"
        case .fileExists: "file-exists"
        case .fileContains: "file-contains"
        case .fileHash: "file-hash"
        case .exeVersion: "exe-version"
        case .msiSummary: "msi-summary"
        case .volumeName: "volume-name"
        }
    }

    /// The file it looks at, if it looks at one.
    var file: String? {
        switch self {
        case .fileExists(let file), .fileContains(let file, _), .fileHash(let file, _, _, _),
             .exeVersion(let file, _, _), .msiSummary(let file, _):
            file
        case .text, .word, .volumeName:
            nil
        }
    }

    /// How specific a match by this matcher is: the length of the text it
    /// matched, a glob's without its wildcards; a hash, which names one
    /// file exactly, beats any text.
    public var specificity: Specificity {
        switch self {
        case .text(let text), .word(let text), .fileContains(_, let text), .exeVersion(_, _, let text),
             .msiSummary(_, let text):
            Specificity(exact: false, length: text.count)
        case .fileExists(let glob), .volumeName(let glob):
            Specificity(exact: false, length: glob.count { !"*?[]".contains($0) })
        case .fileHash:
            Specificity(exact: true, length: 0)
        }
    }

    /// What a match by this matcher says: its kind and its text, for a log.
    public var description: String {
        switch self {
        case .text(let text), .word(let text): "\(kind) \"\(text)\""
        case .fileExists(let file): "\(kind) \(file)"
        case .fileContains(let file, let text): "\(kind) \(file) \"\(text)\""
        case .fileHash(let file, let size, let md5, let bytes): "\(kind) \(file) \(size) bytes, md5 of \(bytes) \(md5)"
        case .exeVersion(let file, let key, let text): "\(kind) \(file) \(key) \"\(text)\""
        case .msiSummary(let file, let subject): "\(kind) \(file) \"\(subject)\""
        case .volumeName(let name): "\(kind) \"\(name)\""
        }
    }
}

/// How specific a match is, to choose between matches: no matcher comes
/// before another, the most specific wins.
public nonisolated struct Specificity: Comparable, Hashable, Sendable {
    /// A hash: one file, exactly.
    public let exact: Bool
    /// The length of the text matched.
    public let length: Int

    public static func < (lhs: Specificity, rhs: Specificity) -> Bool {
        (lhs.exact ? 1 : 0, lhs.length) < (rhs.exact ? 1 : 0, rhs.length)
    }
}

// MARK: - Reading a manifest's matchers

nonisolated extension Matcher: Decodable {
    /// A manifest's matcher is an object with one key, its kind (the schema
    /// checks there is only one); its keys arrive camel-cased
    /// (`Manifest.decodeKebab`).
    private enum Kind: String, CodingKey {
        case fileExists, fileContains, fileHash, exeVersion, msiSummary, volumeName
    }

    private struct FileText: Decodable {
        let file: String
        let text: String
    }

    private struct FileHash: Decodable {
        let file: String
        let size: Int
        let md5: String
        let bytes: Int?
    }

    private struct ExeVersion: Decodable {
        let file: String
        let key: String
        let text: String
    }

    private struct MSI: Decodable {
        let file: String?
        let subject: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Kind.self)
        guard let kind = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a matcher with no kind"))
        }
        switch kind {
        case .fileExists:
            self = .fileExists(file: try container.decode(String.self, forKey: kind))
        case .fileContains:
            let value = try container.decode(FileText.self, forKey: kind)
            self = .fileContains(file: value.file, text: value.text)
        case .fileHash:
            let value = try container.decode(FileHash.self, forKey: kind)
            self = .fileHash(file: value.file, size: value.size, md5: value.md5.lowercased(),
                             bytes: value.bytes ?? Self.defaultHashBytes)
        case .exeVersion:
            let value = try container.decode(ExeVersion.self, forKey: kind)
            self = .exeVersion(file: value.file, key: value.key, text: value.text)
        case .msiSummary:
            let value = try container.decode(MSI.self, forKey: kind)
            self = .msiSummary(file: value.file ?? Self.defaultMSI, subject: value.subject)
        case .volumeName:
            self = .volumeName(try container.decode(String.self, forKey: kind))
        }
    }
}
