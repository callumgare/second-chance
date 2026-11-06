//
//  WinePaths.swift
//  WineKit
//
//  The wine module's answers about its path type, `wine:`.

import Foundation
import WrappModules

/// `wine:C:/…`: a path on a drive of the game's Windows, its prefix. Its C:
/// is the prefix's `drive_c` in the app; another drive (a disc, a store
/// mounted as `A:`) has no place of its own there.
public nonisolated enum WinePaths: ModulePaths {
    public static let typeNames = ["wine"]

    /// Where the prefix's C: is, from the app's `Contents/`.
    static let driveC = "SharedSupport/prefix/drive_c"

    public static func location(of path: String, type: String, in contents: URL) -> URL? {
        onDriveC(path).map { contents.appendingPathComponent(driveC).appendingPathComponent(String($0.drop { $0 == "/" })) }
    }

    public static func describe(_ path: String, type: String) -> String? {
        guard let drive = path.first, path.dropFirst().hasPrefix(":") else { return nil }
        return drive.uppercased() == "C" ? "\(path), on the game's Windows hard drive (Wine)"
            : "\(path), on drive \(drive.uppercased()): of the game's Windows (Wine)"
    }

    public static func legacyProgramPath(of path: String, type: String) -> String? { onDriveC(path) }

    /// A path on C: from the drive's root (`C:/Game/x.exe` is `/Game/x.exe`,
    /// `C:` is `/`); nil for one on another drive.
    static func onDriveC(_ path: String) -> String? {
        guard path.uppercased().hasPrefix("C:") else { return nil }
        let rest = String(path.dropFirst(2))
        guard rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("\\") else { return nil }
        return rest.isEmpty ? "/" : rest.replacingOccurrences(of: "\\", with: "/")
    }
}
