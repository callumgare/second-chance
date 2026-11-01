//
//  WineDrives.swift
//  SecondChanceKit
//
//  A prefix's drive letters, and where the games find what they need.

import Foundation

nonisolated extension Wine {
    /// The prefix's drive letters.
    public var drives: WineDrives { WineDrives(wine: self) }

    /// The prefix's C: drive.
    public var driveC: URL { prefix.appendingPathComponent("drive_c") }

    /// The Windows user's Documents, where the games keep their saves: a
    /// link to whatever the A: drive shows.
    public var documents: URL { driveC.appendingPathComponent("users/\(Self.username)/Documents") }
}

/// A prefix's drive letters: each a link, in its `dosdevices` folder, to
/// the folder that drive shows.
///
/// A wrapp's drives are set when its prefix is made (`WineManager`): only
/// A:, C: and Z:, with every other letter blocked so Wine can't add the
/// Mac's disks. A build mounts each copied disc from D: on, marked as a
/// CD-ROM drive, for a game that checks for its disc.
///
/// A: is the player's saves. Each launch points it at the wrapp's folder in
/// Application Support, and Documents links to the same place, so a game
/// saving to either reaches it. A build points it at a folder in /tmp that
/// may not exist, and links Documents there too: a wrapp run from somewhere
/// it can't write then still has a place its links lead.
nonisolated public struct WineDrives: Sendable {
    let wine: Wine

    /// What kind of drive a letter is, as Wine's registry has it.
    public enum Kind: String, Sendable {
        case hardDisk = "hd"
        case cdrom
    }

    /// Where the links are.
    public var folder: URL { wine.prefix.appendingPathComponent("dosdevices") }

    /// The link for `letter`.
    public func link(_ letter: Character) -> URL {
        folder.appendingPathComponent("\(letter.lowercased()):")
    }

    /// Show `target` as `letter`, in place of whatever it showed. A relative
    /// target is kept as it is, relative to `folder`, so it still works
    /// once the prefix is copied or moved.
    public func mount(_ target: String, as letter: Character) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = link(letter)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    }

    /// Show the folder at `target` as `letter`.
    public func mount(_ target: URL, as letter: Character) throws {
        try mount(target.path, as: letter)
    }

    /// Tell Wine what kind of drive `letter` is.
    public func setKind(_ kind: Kind, of letter: Character) async throws {
        try await wine.registry.set(.string(kind.rawValue), for: "\(letter.lowercased()):", in: .wineDrives)
    }

    /// The target `letter` shows, as it was mounted.
    public func target(of letter: Character) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link(letter).path)
    }

    /// Remove every drive.
    public func removeAll() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for drive in contents {
            try? FileManager.default.removeItem(at: drive)
        }
    }

    /// Keep Wine from giving `letters` to the Mac's own disks: it only adds
    /// a drive at a letter that has nothing there, and a plain file is
    /// something.
    public func block(_ letters: String) {
        for letter in letters {
            FileManager.default.createFile(atPath: link(letter).path, contents: nil)
        }
    }
}
