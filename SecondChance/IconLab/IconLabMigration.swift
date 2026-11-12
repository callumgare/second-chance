//
//  IconLabMigration.swift
//  SecondChance
//
//  Bringing the standalone Icon Lab's data (a checkout's
//  .local/tools/icon-lab/data) into the app's Icon Lab folder, the first
//  time the window opens with nothing in it yet. It's moved, never copied
//  and deleted by hand: on one volume that's a rename, and FileManager only
//  removes the original once a move across volumes has finished.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab")

nonisolated enum IconLabMigration {
    /// The old data to offer, when there is some and the new folder holds nothing yet.
    static func offer(from old: URL?, to new: URL) -> URL? {
        guard let old, FileManager.default.fileExists(atPath: old.path), !isEmpty(old), isEmpty(new) else { return nil }
        return old
    }

    /// Whether `folder` has no files in it, at any depth (empty folders don't count). A missing folder is empty.
    static func isEmpty(_ folder: URL) -> Bool {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [], errorHandler: nil) else { return true }
        for case let url as URL in walk {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { return false }
        }
        return true
    }

    /// Moves `old` to be `new`. `new` must hold no files: its empty folders are cleared out of the way first.
    static func move(_ old: URL, to new: URL) throws {
        let fm = FileManager.default
        guard isEmpty(new) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: new.path]) }
        if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) }
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        logger.notice("Moving Icon Lab's data from \(old.path) to \(new.path)")
        try fm.moveItem(at: old, to: new)
    }
}
