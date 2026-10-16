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

    /// Walk `url` and add up its regular files. Symlinks aren't followed.
    static func measure(_ url: URL) -> DirectorySize {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return DirectorySize(bytes: 0, files: 0)
        }
        var bytes: Int64 = 0
        var files = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
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
