//
//  TestHelpers.swift
//  SecondChanceTests
//
//  Helpers for the per-game integration tests. Resolves installer ISO paths,
//  detects whether installers are present (for test disabling), and reads
//  wrapper Info.plist values for post-install assertions.

import Foundation
@testable import SecondChance

/// Enumerate the repo root regardless of test working directory.
enum TestPaths {
    /// The repository root directory (parent of `SecondChanceTests/`).
    static let repoRoot: URL = {
        // Tests run with the host app's bundle; derive repo root from #filePath.
        let thisFile = URL(fileURLWithPath: #filePath)
        // thisFile = .../SecondChanceTests/Integration/TestHelpers.swift
        return thisFile
            .deletingLastPathComponent()  // Integration/
            .deletingLastPathComponent()  // SecondChanceTests/
            .deletingLastPathComponent()  // repo root
    }()

    /// The `installers/` directory at the repo root.
    static let installersDir: URL = repoRoot.appendingPathComponent("installers")
}

/// Resolves installer ISO paths for a given game.
enum InstallerPaths {
    /// The path to `installers/<slug>/disk-N.iso`, or `nil` if it doesn't exist.
    static func diskISO(for game: GameInfo, diskNumber: Int) -> URL? {
        let isoURL = TestPaths.installersDir
            .appendingPathComponent(game.id)
            .appendingPathComponent("disk-\(diskNumber).iso")

        return FileManager.default.fileExists(atPath: isoURL.path) ? isoURL : nil
    }

    /// The path to a directory containing the disk contents (as an alternative
    /// to an ISO). Returns `nil` if no such directory exists.
    static func diskDirectory(for game: GameInfo) -> URL? {
        let dirURL = TestPaths.installersDir.appendingPathComponent(game.id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        // Only return it if it contains files (not just disk-N.iso at top level)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)
        return (contents?.isEmpty == false) ? dirURL : nil
    }
}

/// Whether any installer ISOs are present in `installers/`. Used by the
/// `.disabled(if:)` trait so integration tests no-op cleanly on CI / machines
/// without the (gitignored) real installers.
enum InstallersPresent {
    static func check() -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: TestPaths.installersDir.path) else {
            return false
        }
        for entry in entries {
            let dir = TestPaths.installersDir.appendingPathComponent(entry)
            let iso = dir.appendingPathComponent("disk-1.iso")
            if fm.fileExists(atPath: iso.path) { return true }
        }
        return false
    }
}

/// Reads values from a built wrapper's `Info.plist` for post-install assertions.
enum WrapperInfo {
    /// Read the raw Info.plist dictionary from a wrapper `.app`.
    static func readPlist(at wrapperPath: URL) throws -> [String: Any] {
        let plistPath = wrapperPath.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            throw NSError(domain: "WrapperInfo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Info.plist not found at \(plistPath.path)"
            ])
        }
        let data = try Data(contentsOf: plistPath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "WrapperInfo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Info.plist is not a valid dictionary"
            ])
        }
        return plist
    }

    /// The `GameExePath` value from the wrapper's Info.plist (the exe path the
    /// wrapper was configured to launch).
    static func gameExePath(at wrapperPath: URL) throws -> String? {
        let plist = try readPlist(at: wrapperPath)
        return plist["GameExePath"] as? String
    }

    /// The `GameSlug` value from the wrapper's Info.plist.
    static func gameSlug(at wrapperPath: URL) throws -> String? {
        let plist = try readPlist(at: wrapperPath)
        return plist["GameSlug"] as? String
    }
}
