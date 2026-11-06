//
//  DOSBoxPaths.swift
//  DOSBoxKit
//
//  The dosbox module's answers about its path type, `dosbox:`.

import Foundation
import WrappModules

/// `dosbox:C:/…`: a path on the drive a DOS program sees, which is the
/// app's `SharedSupport/dosbox/c`.
public nonisolated enum DOSBoxPaths: ModulePaths {
    public static let typeNames = ["dosbox"]

    /// Where DOSBox's C: is, from the app's `Contents/`.
    static let driveC = "SharedSupport/dosbox/c"

    public static func location(of path: String, type: String, in contents: URL) -> URL? {
        onDriveC(path).map { contents.appendingPathComponent(driveC).appendingPathComponent(String($0.drop { $0 == "/" })) }
    }

    public static func describe(_ path: String, type: String) -> String? { "\(path), on the DOS program's drive (DOSBox)" }

    public static func legacyProgramPath(of path: String, type: String) -> String? { onDriveC(path) }

    /// A path on C: from the drive's root (`C:/TYRIAN/X.EXE` is `/TYRIAN/X.EXE`).
    static func onDriveC(_ path: String) -> String? {
        guard path.uppercased().hasPrefix("C:") else { return nil }
        let rest = String(path.dropFirst(2))
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        return rest.isEmpty ? "/" : rest
    }
}
