//
//  ImageRecord.swift
//  ProgramImages
//
//  What the crawl says about each distinct image (records.jsonl), and the
//  events it reports as it goes (stdout of icon-extract): the schema
//  docs/program-images.md documents.

import Foundation

/// Why an image might be the program's icon, or why not.
nonisolated public enum ImageRole: String, Codable, Sendable, CaseIterable {
    /// The first icon group of the program the wrapp launches (or another
    /// sure sign of the main program).
    case mainProgramIcon = "main-program-icon"
    /// The first icon group of the program that looks likeliest to be the
    /// main one, when nothing said which it is.
    case likelyMainProgramIcon = "likely-main-program-icon"
    /// The icon a shortcut the installer made shows.
    case shortcutIcon = "shortcut-icon"
    /// The icon autorun.inf gives the disc.
    case autorunIcon = "autorun-icon"
    /// A disc's or volume's own icon (an HFS volume's `Icon\r`, `.VolumeIcon.icns`).
    case volumeIcon = "volume-icon"
    /// From an MSI's Icon table, which its shortcuts show.
    case msiIcon = "msi-icon"
    /// A classic Mac application's own icon family, through its bundle.
    case macAppIcon = "mac-app-icon"
    /// A classic Mac file's or folder's custom icon.
    case customIcon = "custom-icon"
    /// A Mac app bundle's icon (a wrapp's own is `wrapp-icon`).
    case appBundleIcon = "app-bundle-icon"
    case wrappIcon = "wrapp-icon"
    /// From a program's first icon group: what Explorer shows for it.
    case firstIconGroup = "first-icon-group"
    /// From any icon group or icon file.
    case icon
    /// An installer's own icon (usually the program's).
    case installerOwnIcon = "installer-own-icon"
    /// An installer's dialog art: wizard and banner bitmaps.
    case installerArt = "installer-art"
    /// A name like logo, title, splash, box or cover.
    case titleLikeName = "title-like-name"
    /// A name like button, cursor, font, mask or tile.
    case uiLikeName = "ui-like-name"
    /// From a runtime library or a system folder.
    case runtimeLibrary = "runtime-library"
    case cursor
    case bitmapResource = "bitmap-resource"
    case picture
    case videoFrame = "video-frame"
    /// Found by its signature inside something unread.
    case carved
}

/// One distinct image (by its decoded pixels), every place it was found,
/// and how it ranks.
nonisolated public struct ImageRecord: Codable, Sendable {
    public struct Provenance: Codable, Sendable {
        public let steps: [Step]
        public let display: String
    }

    public let sha256: String
    /// `<sha256>.png`, beside records.jsonl.
    public let file: String
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let hasAlpha: Bool
    /// The representative's sha256: sizes and depths of the same art share it.
    public var familyID: String
    public var isFamilyRepresentative: Bool
    public var familySize: Int
    /// Up to 50 of the places it was found; `sources` counts them all.
    public let provenance: [Provenance]
    public let sources: Int
    public let roles: [ImageRole]
    public let score: Double
    public let scoreReasons: [String]
    /// 64-bit difference hash, hex.
    public let dHash: String

    enum CodingKeys: String, CodingKey {
        case sha256, file, width, height, bitDepth, hasAlpha
        case familyID = "familyId"
        case isFamilyRepresentative, familySize, provenance, sources, roles, score, scoreReasons, dHash
    }
}

/// An event of the crawl, one JSON object a line, `event` naming which.
nonisolated public enum ExtractionEvent: Sendable {
    /// A node was reached: a file, entry, partition, resource set.
    case node(id: Int, parent: Int?, name: String, kind: String, size: Int, depth: Int, display: String,
              installer: String?, macType: String? = nil)
    /// An image was decoded: new (written as its PNG), or a duplicate of one
    /// already found, from another place.
    case image(sha256: String, node: Int, width: Int, height: Int, bitDepth: Int, display: String, isNew: Bool)
    /// Something wasn't looked into, and why.
    case skip(node: Int?, name: String, reason: String)
    case progress(nodes: Int, images: Int, queued: Int, bytesExtracted: Int)
    case done(nodes: Int, images: Int, families: Int, skipped: Int, records: String, seconds: Double)

    public var json: [String: Any] {
        switch self {
        case let .node(id, parent, name, kind, size, depth, display, installer, macType):
            var object: [String: Any] = ["event": "node", "id": id, "name": name, "kind": kind, "size": size,
                                         "depth": depth, "display": display]
            if let parent { object["parent"] = parent }
            if let installer { object["installer"] = installer }
            if let macType { object["macType"] = macType }
            return object
        case let .image(sha256, node, width, height, bitDepth, display, isNew):
            return ["event": "image", "sha256": sha256, "node": node, "width": width, "height": height,
                    "bitDepth": bitDepth, "display": display, "new": isNew]
        case let .skip(node, name, reason):
            var object: [String: Any] = ["event": "skip", "name": name, "reason": reason]
            if let node { object["node"] = node }
            return object
        case let .progress(nodes, images, queued, bytes):
            return ["event": "progress", "nodes": nodes, "images": images, "queued": queued, "bytesExtracted": bytes]
        case let .done(nodes, images, families, skipped, records, seconds):
            return ["event": "done", "nodes": nodes, "images": images, "families": families, "skipped": skipped,
                    "records": records, "seconds": (seconds * 10).rounded() / 10]
        }
    }

    /// The event as one line of JSON, keys sorted.
    public var jsonLine: String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
