//
//  EngineTree.swift
//  WrappBuilder
//
//  A prepared engine's files, and the hash that says they are the ones
//  that were tested.

import CryptoKit
import Darwin
import Foundation

/// A prepared engine: a folder laid out as a wrapp's `Contents/`
/// (`SharedSupport/wine`, `Frameworks/…`, `MacOS/scummvm`), with the list
/// of its files at `Resources/engines/<module>.files`, which is what a wrapp
/// removes when it changes engine.
public nonisolated enum EngineTree {
    /// Where in a tree, and in a wrapp's `Contents/`, a module's list is.
    public static func listPath(module: String) -> String {
        "Resources/engines/\(module).files"
    }

    /// Every regular file and link in `folder`, by its path in it, sorted.
    public static func files(in folder: URL) throws -> [String] {
        try entries(in: folder).filter { $0.kind != .directory }.map(\.path)
    }

    /// Write `folder`'s list of its files into it.
    public static func writeList(module: String, in folder: URL) throws {
        let list = folder.appendingPathComponent(listPath(module: module))
        try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        let files = try files(in: folder).filter { $0 != listPath(module: module) } + [listPath(module: module)]
        try Data((files.sorted().joined(separator: "\n") + "\n").utf8).write(to: list)
    }

    /// What makes two trees the same: each entry's path and kind, a file's
    /// contents and whether it is executable, a link's target, and the code
    /// signature a file that isn't Mach-O keeps in its extended attributes
    /// (`com.apple.cs.*`). Not times, owners, or other attributes, which a
    /// download or a copy changes (`com.apple.provenance`, quarantine).
    public static func hash(of folder: URL) throws -> String {
        var digest = SHA256()
        for entry in try entries(in: folder) {
            let url = folder.appendingPathComponent(entry.path)
            var line: String
            switch entry.kind {
            case .directory:
                line = "d \(entry.path)"
            case .link:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                line = "l \(entry.path) \(target)"
            case .file(let executable):
                line = "f \(entry.path) \(executable ? "x" : "-") \(try fileHash(url))"
                for (name, value) in signatureAttributes(of: url) {
                    line += " \(name)=\(SHA256.hash(data: value).hex)"
                }
            }
            digest.update(data: Data((line + "\n").utf8))
        }
        return digest.finalize().hex
    }

    // MARK: - Walking

    struct Entry {
        enum Kind: Equatable {
            case directory, link, file(executable: Bool)
        }

        let path: String
        let kind: Kind
    }

    static func entries(in folder: URL) throws -> [Entry] {
        let root = folder.resolvingSymlinksInPath().path
        guard let walk = FileManager.default.enumerator(atPath: root) else {
            throw EngineError("can't read \(folder.path)")
        }
        var entries: [Entry] = []
        while let path = walk.nextObject() as? String {
            var info = stat()
            guard lstat(root + "/" + path, &info) == 0 else { throw EngineError("can't read \(path) in \(folder.path)") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: entries.append(Entry(path: path, kind: .directory))
            case S_IFLNK: entries.append(Entry(path: path, kind: .link))
            case S_IFREG: entries.append(Entry(path: path, kind: .file(executable: info.st_mode & S_IXUSR != 0)))
            default: throw EngineError("\(path) in \(folder.path) is neither a file, a folder nor a link")
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().hex
    }

    /// The `com.apple.cs.*` extended attributes of the file at `url`, by name.
    static func signatureAttributes(of url: URL) -> [(String, Data)] {
        let path = url.path
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [] }
        let all = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return all.filter { $0.hasPrefix("com.apple.cs.") }.sorted().compactMap { name in
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { return nil }
            var value = Data(count: length)
            let read = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            return read == length ? (name, value) : nil
        }
    }
}

nonisolated extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
