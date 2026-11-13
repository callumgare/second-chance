//
//  FileTree.swift
//  ProcessKit
//
//  Removing a tree of files that may hold folders without write permission
//  for their owner. A file can't be removed from such a folder, so
//  `FileManager.removeItem` fails partway, leaving what it hadn't reached.
//  A game disc copied into a wrapp kept its root's read-only mode
//  (`r-xr-xr-x`) until 2026-11-13, so wrapps and cached layers made before
//  then hold folders like that.

import Foundation

nonisolated public enum FileTree {
    /// Give the owner write permission on `root` and every folder and file
    /// in it that lacks it. Links aren't followed.
    public static func makeOwnerWritable(_ root: URL) throws {
        let fileManager = FileManager.default
        var items = [root]
        if let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            items += walker.compactMap { $0 as? URL }
        }
        for url in items {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  let mode = attributes[.posixPermissions] as? Int, mode & 0o200 == 0 else { continue }
            try fileManager.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: url.path)
        }
    }

    /// Remove `url` and everything in it. When a removal is refused for want
    /// of permission, the tree is made owner-writable and removed again.
    public static func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where isPermissionError(error) {
            try makeOwnerWritable(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Whether `error` is a removal refused for want of permission.
    static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }
}
