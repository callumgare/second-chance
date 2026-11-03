//
//  WineDrives.swift
//  WineKit
//
//  A prefix's drive letters, and where the games find what they need.

import Foundation
import WrappLogging
import ProcessKit

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
/// A: and C:, with every other letter blocked so Wine can't add the Mac's
/// disks. There is no Z: showing the whole Mac, as Wine would have, so a
/// Windows program that goes looking through every drive, or goes wrong
/// there, reaches only the game's own files and the saves. A build mounts
/// each copied disc from D: on, marked as a CD-ROM drive, for a game that
/// checks for its disc, and lends Y: to the folder of an installer outside
/// the prefix while it runs (`lend`). A wrapp built when there was a Z:
/// blocks it as it launches.
///
/// Wine isn't a sandbox: a program can still name any Mac file through
/// Wine's `\\?\unix\` paths. Leaving out Z: keeps a program from reaching
/// the Mac by accident, not one that sets out to.
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

    /// Tell Wine what kind of drive each of `letters` is, with one Wine run.
    /// Nothing need be at a letter yet: Wine reads its kind when it finds a
    /// drive there.
    public func setKind(_ kind: Kind, of letters: [Character]) async throws {
        try await wine.registry.set(letters.map { ("\($0.lowercased()):", .string(kind.rawValue)) }, in: .wineDrives)
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
    /// something. A drive already at a letter is removed first (the link,
    /// not what it shows).
    public func block(_ letters: String) {
        for letter in letters {
            let path = link(letter).path
            try? FileManager.default.removeItem(atPath: path)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    /// The letter `lend` shows a folder as.
    public static let lentLetter: Character = "y"

    /// Show `folder` as Y: until `takeBack()`, so a Windows program can run
    /// a file in it, and see nothing else of the Mac: an installer the
    /// person saved, or one Second Chance downloaded. Wine names a Mac path
    /// under `folder` Y:\…, as it names one under the prefix's drive_c C:\…,
    /// so the Mac path can be given as it is.
    public func lend(_ folder: URL) throws {
        try mount(folder, as: Self.lentLetter)
    }

    /// Block Y: again after `lend`.
    public func takeBack() {
        block(String(Self.lentLetter))
    }
}
