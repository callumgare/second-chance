//
//  BasiliskPaths.swift
//  BasiliskKit
//
//  The basilisk module's answers about its path type, `basilisk:`.

import Foundation
import WrappModules

/// `basilisk:Ingenious CD:Ingenious`: a file on the emulated Mac's disks, in
/// Mac OS's own form (a disk's name, then folders, colon-separated). It's on
/// a disk image, never a file the host can reach, so it has no place in the
/// app, and older settings have no name for it.
public nonisolated enum BasiliskPaths: ModulePaths {
    public static let typeNames = ["basilisk"]

    public static func location(of path: String, type: String, in contents: URL) -> URL? { nil }

    public static func describe(_ path: String, type: String) -> String? {
        let parts = path.split(separator: ":", omittingEmptySubsequences: true)
        guard let disk = parts.first, let name = parts.last, parts.count > 1 else { return "\(path), on the game's Mac" }
        return "\(name), on the game's Mac's disk \(disk)"
    }
}
