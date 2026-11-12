//
//  Node.swift
//  ProgramImages
//
//  Anything with bytes the crawl looks into — a file on the Mac, an entry in
//  a disc or archive, a resource in a program, a fork — with the chain of
//  steps that reached it. Native readers hand on ranges of their parent
//  (an ISO extent, a resource) rather than copies, so most of the crawl
//  never writes to disk.

import ClassicMacFormats
import Foundation

/// One step of an image's provenance.
nonisolated public struct Step: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// The input itself, or a file on the Mac.
        case file
        /// A file inside a container: a disc, an archive, an installer.
        case entry
        /// A partition or volume of a disc.
        case volume
        /// A resource of a program or a resource fork.
        case resource
        /// A Mac file's resource fork.
        case fork
        /// What follows a program's last section.
        case overlay
        /// An image found by its signature inside something else.
        case carved
        /// A frame of a video.
        case frame
        /// The image itself: its size and depth.
        case image
    }

    public let kind: Kind
    public let name: String
    /// Extra: the tool that unpacked an entry ("via innoextract").
    public let detail: String?

    public init(_ kind: Kind, _ name: String, detail: String? = nil) {
        self.kind = kind
        self.name = name
        self.detail = detail
    }

    /// `disc.iso › SETUP.EXE › data1.cab › Game.exe › RT_GROUP_ICON 101 › 48×48 32-bit`
    public static func display(_ chain: [Step]) -> String {
        chain.map(\.name).joined(separator: " › ")
    }
}

/// A classic Mac file's Finder info and resource fork, wherever it was found.
nonisolated public struct MacMetadata: Sendable {
    public var type: String
    public var creator: String
    public var finderFlags: Int
    public var resourceFork: Data?
    /// At the root of an HFS volume: an `Icon\r` there is the volume's icon.
    public var isVolumeRoot = false

    public init(type: String, creator: String, finderFlags: Int, resourceFork: Data?, isVolumeRoot: Bool = false) {
        self.type = type
        self.creator = creator
        self.finderFlags = finderFlags
        self.resourceFork = resourceFork
        self.isVolumeRoot = isVolumeRoot
    }
}

nonisolated public struct Node: Sendable {
    public enum Content: Sendable {
        case hostFile(URL)
        case hostDirectory(URL)
        case bytes(Data)
        case source(any ByteSource)
        /// Read when needed: a fragmented fork of an HFS file.
        case lazy(size: Int, load: @Sendable () -> Data?)
    }

    public let id: Int
    public let parentID: Int?
    public let chain: [Step]
    /// How many containers deep.
    public let depth: Int
    public let content: Content
    public var mac: MacMetadata?
    /// Roles every image found in or below this node gets: an MSI icon's,
    /// a runtime library's.
    public var roles: Set<ImageRole> = []
    /// Its siblings in the container it came from, by name, for tools that
    /// read a set of files (InstallShield's data1.hdr beside data1.cab).
    public var siblings: (@Sendable (String) -> Content?)?

    public var name: String {
        let last = chain.last?.name ?? ""
        return last.split(separator: "/").last.map(String.init) ?? last
    }

    /// The path the node was found at, as lower-cased components: every
    /// file and entry step's path, so a shortcut's `C:\Game\game.exe` can
    /// be matched against the end of it.
    public var matchPath: [String] {
        chain.filter { $0.kind == .file || $0.kind == .entry }
            .flatMap { $0.name.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) }
    }

    public var size: Int {
        switch content {
        case .hostFile(let url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        case .hostDirectory: return 0
        case .bytes(let data): return data.count
        case .source(let source): return source.count
        case .lazy(let size, _): return size
        }
    }

    /// All of the node's bytes, mapped for a file on the Mac. Nil for a
    /// folder, or what can't be read.
    public func data() -> Data? {
        switch content {
        case .hostFile(let url):
            return try? Data(contentsOf: url, options: .alwaysMapped)
        case .hostDirectory: return nil
        case .bytes(let data): return data
        case .source(let source):
            if let data = source as? Data { return data }
            guard source.count <= 1 << 30 else { return nil }
            return source.read(0..<source.count)
        case .lazy(_, let load): return load()
        }
    }

    /// The bytes by range, for a disc or volume too big to want whole.
    public func byteSource() -> (any ByteSource)? {
        switch content {
        case .source(let source): return source
        default: return data()
        }
    }
}
