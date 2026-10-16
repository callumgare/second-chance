//
//  DirectorySize.swift
//  Shared
//
//  The size and file count of a directory tree, for logging what an install
//  actually produced.

import Foundation

nonisolated struct DirectorySize: Equatable, Sendable {
    let bytes: Int64
    let files: Int

    /// Walk `url` and add up its regular files. Symlinks are followed, once
    /// each: a ScummVM game's `disk-combined` folder is links into its disks.
    static func measure(_ url: URL) -> DirectorySize {
        var visited = Set<String>()
        var bytes: Int64 = 0
        var files = 0
        var pending = [url.resolvingSymlinksInPath()]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        while let next = pending.popLast() {
            guard visited.insert(next.path).inserted,
                  let values = try? next.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: next, includingPropertiesForKeys: Array(keys)
                )) ?? []
                pending += children.map { $0.resolvingSymlinksInPath() }
            } else if values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
                files += 1
            }
        }
        return DirectorySize(bytes: bytes, files: files)
    }

    /// `559 MB in 2,056 files`.
    var description: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let count = NumberFormatter.localizedString(from: NSNumber(value: files), number: .decimal)
        return "\(size) in \(count) file\(files == 1 ? "" : "s")"
    }
}
