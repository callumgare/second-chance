//
//  DetectionSource.swift
//  WrappBuilder
//
//  What a disc or download shows of itself: the names it gives itself, and
//  the files the matchers that look at files read.

import Foundation
import CryptoKit
import WindowsFormats

/// A disc or download being recognised: the names it gives itself, in the
/// order they were read, and where its files are.
public nonisolated struct DetectionSource: Sendable {
    /// Where a name came from: what a near-miss report says the source had,
    /// without the name itself.
    public enum SignalKind: String, Sendable, Hashable {
        /// `setup.exe`'s version info, or a download's own.
        case exeVersion = "exe-version"
        /// An MSI's summary information.
        case msi
        /// `setup.ini`'s `AppName` and `Product`.
        case setupIni = "setup.ini"
        /// `autorun.inf`'s label.
        case autorun = "autorun.inf"
        /// The name of the disc's folder: its volume name when it is mounted.
        case folderName = "folder-name"
        /// A download's file name.
        case fileName = "file-name"
        /// Names a download carries as plain text.
        case embedded
        /// The names a Mac download's Cider app gives itself.
        case cider
    }

    public struct Signal: Hashable, Sendable {
        public let kind: SignalKind
        public let text: String

        public init(_ kind: SignalKind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Where file matchers look.
    public enum Location: Hashable, Sendable {
        /// A disc, or a folder: its files, from its top.
        case folder(URL)
        /// A download: the one file, by its name.
        case file(URL)
    }

    public var signals: [Signal]
    public var location: Location?
    /// The volume's name, when `location` is a mounted disc's top.
    public var volumeName: String?

    public init(signals: [Signal], location: Location? = nil, volumeName: String? = nil) {
        self.signals = signals
        self.location = location
        self.volumeName = volumeName
    }

    /// Every name, joined: what the `text` and `word` matchers look in.
    public var fingerprint: String {
        signals.map(\.text).joined(separator: " ")
    }

    /// The kinds of name the source had, in order, each once.
    public var signalKinds: [SignalKind] {
        var seen = Set<SignalKind>()
        return signals.map(\.kind).filter { seen.insert($0).inserted }
    }
}

// MARK: - Its files

/// How Windows programs' version info and MSIs' summaries are read:
/// WindowsFormats' readers, or a test's.
public nonisolated struct WindowsReaders: Sendable {
    public var versionStrings: @Sendable (URL) -> [String: String]?
    public var msiSubject: @Sendable (URL) -> String?

    public init(versionStrings: @escaping @Sendable (URL) -> [String: String]?,
                msiSubject: @escaping @Sendable (URL) -> String?) {
        self.versionStrings = versionStrings
        self.msiSubject = msiSubject
    }

    public static let standard = WindowsReaders(
        versionStrings: { WindowsExecutable(contentsOf: $0)?.versionStrings },
        msiSubject: { MSISummary(contentsOf: $0)?.subject }
    )
}

/// A source's files, listed as deep as the index's globs go, once per
/// detection, and what has been read of them.
nonisolated final class SourceFiles {
    /// Each file's path from the top, and where it is.
    private let files: [(path: String, url: URL)]
    private var hashes: [String: String] = [:]
    private let readers: WindowsReaders

    /// The longest a `file-contains` matcher reads.
    static let containsLimit = 16 << 20

    init(_ location: DetectionSource.Location?, depth: Int, readers: WindowsReaders) {
        self.readers = readers
        switch location {
        case .file(let url):
            files = depth > 0 ? [(url.lastPathComponent, url)] : []
        case .folder(let root):
            files = depth > 0 ? Self.list(root, depth: depth) : []
        case nil:
            files = []
        }
    }

    /// The files whose path `glob` matches, case aside, `*` and `?` not
    /// crossing a `/`.
    func matching(_ glob: String) -> [(path: String, url: URL)] {
        files.filter { Self.glob(glob, matches: $0.path) }
    }

    static func glob(_ glob: String, matches name: String) -> Bool {
        fnmatch(glob, name, FNM_CASEFOLD | FNM_PATHNAME) == 0
    }

    /// The md5 of a file's first `bytes` bytes, in hex; nil if it can't be read.
    func md5(of url: URL, bytes: Int) -> String? {
        let key = "\(bytes):\(url.path)"
        if let known = hashes[key] { return known }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) ?? Data() else { return nil }
        let hex = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        hashes[key] = hex
        return hex
    }

    static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Whether the file's first 16 MB hold `text`, in UTF-8 or UTF-16
    /// (little-endian, as Windows writes it).
    static func file(_ url: URL, contains text: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: containsLimit), !data.isEmpty else { return false }
        let needles = [Data(text.utf8), text.data(using: .utf16LittleEndian)].compactMap { $0 }
        return needles.contains { data.range(of: $0) != nil }
    }

    func versionString(_ key: String, of url: URL) -> String? {
        readers.versionStrings(url)?[key]
    }

    func msiSubject(of url: URL) -> String? {
        readers.msiSubject(url)
    }

    /// Files and folders under `root`, `depth` levels down, hidden ones left out.
    private static func list(_ root: URL, depth: Int) -> [(path: String, url: URL)] {
        var result: [(String, URL)] = []
        var level: [(String, URL)] = [("", root)]
        for _ in 0..<depth {
            var next: [(String, URL)] = []
            for (prefix, folder) in level {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? []
                for entry in entries {
                    let path = prefix.isEmpty ? entry.lastPathComponent : "\(prefix)/\(entry.lastPathComponent)"
                    result.append((path, entry))
                    if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        next.append((path, entry))
                    }
                }
            }
            level = next
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
