//
//  GameFileSnapshot.swift
//  SecondChance
//
//  What a game patch changed in the game folder.

import Foundation
import Logging
import SecondChanceKit

/// The files under a game directory, by size and modification date, so a
/// patch's effect can be logged. Archive extraction keeps a file's original
/// date, so a file a patch adds shows up as new rather than as newer.
nonisolated struct GameFileSnapshot: Sendable {
    private var files: [String: (size: Int, modified: Date)] = [:]

    init(of directory: URL, fileManager: FileManager = .default) {
        let root = directory.resolvingSymlinksInPath().path
        guard let walker = fileManager.enumerator(
            at: directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            files[relative] = (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    /// Paths added, changed or removed since `earlier`, each marked `+`, `~` or `-`.
    func changes(since earlier: GameFileSnapshot) -> [String] {
        var result: [String] = []
        for (path, now) in files {
            if let then = earlier.files[path] {
                if then.size != now.size || then.modified != now.modified { result.append("~\(path)") }
            } else {
                result.append("+\(path)")
            }
        }
        for path in earlier.files.keys where files[path] == nil {
            result.append("-\(path)")
        }
        return result.sorted { $0.dropFirst() < $1.dropFirst() }
    }
}
