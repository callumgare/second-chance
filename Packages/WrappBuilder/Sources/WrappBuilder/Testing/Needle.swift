//
//  Needle.swift
//  WrappBuilder
//
//  What a test looks for on a program's screen, as a bundle or module
//  describes it: a reference, its tags, and where to click it.

import Foundation
import CoreGraphics

/// A needle (openQA's word): something a test recognises on screen, found
/// by its tags. Three kinds: `screen`, a whole-screen fingerprint against an
/// image; `region`, an image matched in part of the screen; `text`, strings
/// read off the screen. Each is a `<name>.yaml`, beside `<name>.png` for an
/// image; a folder's `defaults.yaml` describes every image in it that has no
/// file of its own (docs/testing.md#needles).
public nonisolated struct Needle: Sendable, Equatable {
    /// Its path in its needles folder, without the extension
    /// (`splash/splash-any-her-logo-blue`): a nearer folder's needle of the
    /// same id replaces a farther one's.
    public let id: String
    public let spec: Spec
    /// The reference image, for a `screen` or `region` needle.
    public let image: URL?

    /// The needle's own name, for logs: the last part of its id.
    public var name: String { String(id.split(separator: "/").last ?? Substring(id)) }

    public struct Spec: Decodable, Sendable, Equatable {
        public let kind: Kind
        public let tags: [String]
        /// Where to click, as a fraction of what matched: of the picture
        /// for a `screen` needle, of the found area for the others. Nil
        /// clicks the middle.
        public let click: Point?
        public let region: Region?
        public let text: Text?

        public init(kind: Kind, tags: [String], click: Point? = nil, region: Region? = nil, text: Text? = nil) {
            self.kind = kind
            self.tags = tags
            self.click = click
            self.region = region
            self.text = text
        }
    }

    public enum Kind: String, Decodable, Sendable {
        case screen, region, text
    }

    public struct Point: Decodable, Sendable, Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    /// Where a `region` needle is searched for, and at what size.
    public struct Region: Decodable, Sendable, Equatable {
        /// The part of the screen searched, as fractions with a top-left
        /// origin; nil searches all of it.
        public let search: Rect?
        /// The reference's height as a fraction of the screen's.
        public let heightFraction: Double?
        public let scales: [Double]?
        /// How colour is turned to grey before matching: `luminance`, or
        /// `red-emphasis` for a red button on a dark screen.
        public let grayscale: String?
    }

    public struct Rect: Decodable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// The strings a `text` needle matches, the first found winning.
    public struct Text: Decodable, Sendable, Equatable {
        public let strings: [String]
    }

    /// The point to click in a match `found` (in any units), by `spec.click`.
    public func clickPoint(in found: CGRect) -> CGPoint {
        let fraction = spec.click?.cgPoint ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(x: found.minX + found.width * fraction.x, y: found.minY + found.height * fraction.y)
    }
}

/// The needles a test can look for, from its folders nearest first: an
/// edition's, then the bundle's, then its modules'. A needle in a nearer
/// folder replaces one of the same id in a farther; every other needle is
/// added, and any of a tag's needles matching counts.
public nonisolated struct NeedleLibrary: Sendable {
    public let needles: [Needle]

    public init(needles: [Needle]) { self.needles = needles }

    /// The needles in `folders`, nearest first.
    public static func load(_ folders: [URL]) throws -> NeedleLibrary {
        var byID: [String: Needle] = [:]
        var order: [String] = []
        for folder in folders.reversed() {
            for needle in try loadFolder(folder) {
                if byID[needle.id] == nil { order.append(needle.id) }
                byID[needle.id] = needle
            }
        }
        return NeedleLibrary(needles: order.compactMap { byID[$0] })
    }

    /// The needles carrying `tag`.
    public func tagged(_ tag: String) -> [Needle] {
        needles.filter { $0.spec.tags.contains(tag) }
    }

    /// Every needle in one folder and the folders inside it.
    static func loadFolder(_ root: URL) throws -> [Needle] {
        let files = FileManager.default
        guard files.fileExists(atPath: root.path) else { return [] }
        var needles: [Needle] = []
        let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var folders = [root]
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(url) }
        }
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            let contents = try files.contentsOfDirectory(atPath: folder.path).sorted()
            let defaults = try contents.contains("defaults.yaml")
                ? spec(at: folder.appendingPathComponent("defaults.yaml")) : nil
            let relative = String(folder.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            func id(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }
            for file in contents where file.hasSuffix(".yaml") && file != "defaults.yaml" {
                let name = String(file.dropLast(".yaml".count))
                let image = folder.appendingPathComponent(name + ".png")
                let needle = Needle(id: id(name), spec: try spec(at: folder.appendingPathComponent(file)),
                                    image: files.fileExists(atPath: image.path) ? image : nil)
                if needle.spec.kind != .text, needle.image == nil {
                    throw NeedleError(description: "\(folder.lastPathComponent)/\(file) is a \(needle.spec.kind.rawValue) needle with no \(name).png")
                }
                needles.append(needle)
            }
            for file in contents where file.hasSuffix(".png") {
                let name = String(file.dropLast(".png".count))
                guard !contents.contains(name + ".yaml") else { continue }
                guard let defaults else {
                    throw NeedleError(description: "\(folder.lastPathComponent)/\(file) has no \(name).yaml, and its folder no defaults.yaml")
                }
                needles.append(Needle(id: id(name), spec: defaults, image: folder.appendingPathComponent(file)))
            }
        }
        return needles
    }

    static func spec(at file: URL) throws -> Needle.Spec {
        do {
            return try Manifest.decodeKebab(Needle.Spec.self, from: YAML12.load(String(contentsOf: file, encoding: .utf8)))
        } catch {
            throw NeedleError(description: "\(file.lastPathComponent): \(error)")
        }
    }
}

public nonisolated struct NeedleError: Error, CustomStringConvertible, Equatable {
    public let description: String
}
