//
//  SharedFolders.swift
//  WrappBuilder
//
//  What every user on a Mac shares, in one place: a Mac with test users
//  (docs/dev-cli.md#test-sessions) keeps one installers store, one engine
//  store and every screen's lease for all of them.

import Foundation
import ProcessKit

/// The folders every user on a Mac shares, under `/Users/Shared/second-chance`,
/// and how one is made so that every user can use and add to it.
public nonisolated enum SharedFolders {
    public static let root = URL(fileURLWithPath: "/Users/Shared/second-chance", isDirectory: true)
    /// The Mac's test users, one a line (`sc session add`): its presence says
    /// the Mac has them.
    public static let pool = root.appendingPathComponent("pool")
    /// Disc images and downloads, by bundle, edition and input (`InstallersStore`).
    public static let installers = root.appendingPathComponent("installers", isDirectory: true)
    /// Prepared engines, on a Mac with test users (`EngineStore`).
    public static let engines = root.appendingPathComponent("engines", isDirectory: true)
    /// Each user's screen lease (`sc lease`).
    public static let leases = root.appendingPathComponent("leases", isDirectory: true)

    /// What every user may do in a shared folder, inherited by everything made
    /// in it, so one user's sync or build can replace what another user left.
    public static let everyoneACL = "everyone allow list,add_file,search,delete,add_subdirectory,delete_child,readattr,writeattr,"
        + "readextattr,writeextattr,readsecurity,read,write,append,execute,file_inherit,directory_inherit"

    /// Make `folder` and the shared root above it, if they aren't there, each
    /// usable by every user (`everyoneACL`). Whether it made `folder`.
    @discardableResult
    public static func make(_ folder: URL) async throws -> Bool {
        let files = FileManager.default
        guard !files.fileExists(atPath: folder.path) else { return false }
        for path in [root, folder] where !files.fileExists(atPath: path.path) {
            try files.createDirectory(at: path, withIntermediateDirectories: true)
            let result = try await Process.output(of: "/bin/chmod", ["+a", everyoneACL, path.path])
            guard result.status == 0 else {
                throw SharedFolderError("Couldn't let every user use \(path.path): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return true
    }

    /// `make` as a shell command, for another Mac: `folder` made and shared
    /// unless it's there. Paths are single-quoted.
    public static func makeCommand(_ folder: URL) -> String {
        let quote = { (path: String) in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let steps = [root, folder].map { path in
            "{ [ -d \(quote(path.path)) ] || { mkdir -p \(quote(path.path)) && chmod +a \(quote(everyoneACL)) \(quote(path.path)); }; }"
        }
        return steps.joined(separator: " && ")
    }
}

public struct SharedFolderError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}
