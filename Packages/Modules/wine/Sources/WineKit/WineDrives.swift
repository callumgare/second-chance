//
//  WineDrives.swift
//  WineKit
//
//  A prefix's drive letters, and where the games find what they need.

import Foundation
import Logging
import WrappLogging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.WineDrives")

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
/// A wrapp's drives are set when its prefix is made (`showOnly`, run by
/// `WINE.DRIVES --only=C:`): only A: and C:, with every other letter
/// blocked, and every letter's device link too, so Wine can't add the Mac's
/// disks (see "How Wine adds the Mac's disks" below). There is no Z:
/// showing the whole Mac, as Wine would have, so a
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
///
/// ## How Wine adds the Mac's disks
///
/// Read from Wine 10.0's source (the Wine wrapps carry is built from it).
/// Each letter has two entries in `dosdevices`: `y:`, the folder the drive
/// shows, and `y::`, the device it's on (`/dev/rdisk10`), which Wine reads
/// a disc's label and serial from.
///
/// - Whenever a Wine session starts, its mount manager (`mountmgr.sys`, in
///   `winedevice.exe`) first takes every `x:` link as a drive, and `x::`
///   beside it, if it's a link, as the device that drive is on
///   (`create_drive_devices`, dlls/mountmgr.sys/device.c). It then hears of
///   every disc the Mac has mounted, and of each one mounted later while the
///   session lasts, from Disk Arbitration (dlls/mountmgr.sys/diskarb.c).
/// - For each disc it calls `add_dos_device` with no letter chosen
///   (`device_op`, dlls/mountmgr.sys/mountmgr.c), and `add_drive`
///   (dlls/mountmgr.sys/unixlib.c) picks one, going through the letters
///   (from D: for a CD, from C: for anything else). A letter whose `x::` is a
///   link to that very device is taken at once, whatever is at `x:`. Any
///   other letter is free only if *neither* `x::` nor `x:` exists. Something
///   that isn't a link to a device at `x::` (a plain file) or anything at
///   `x:` puts the letter out of the running.
/// - The letter picked, `add_dos_device` writes `x::` → the device and
///   `x:` → where the disc is mounted, through `set_dosdev_symlink`
///   (unixlib.c), which unlinks whatever is at the name first: a plain file
///   there is replaced, not respected. It also writes the drive's kind
///   (a disk image is a "floppy") in `HKLM\Software\Wine\Drives`.
/// - Only `IOCTL_MOUNTMGR_DEFINE_UNIX_DRIVE` names the letter itself
///   (`define_unix_drive`, mountmgr.c), and it too replaces what's there.
///   That's winecfg's drive tab, which neither a build nor a game uses.
/// - Wine names a Mac path by its drive from the `x:` links alone: it
///   matches the path's folders against each `x:`'s device and inode
///   (`get_drives_info` and `find_drive_rootA`, dlls/ntdll/unix/file.c). A
///   path under no drive is named `\\?\unix\…`.
///
/// So a blocked letter needs a plain file at both `x:` and `x::`, and each
/// entry must go from one thing to the next without a moment where nothing
/// is there (`replace`). Before both were so, an integration run's Steam and
/// Her download builds failed: a prefix layer made while other builds had
/// disc images mounted kept `y::` → `/dev/rdisk10`, most likely written in
/// the instant `WINE.DRIVES` had removed every drive and not yet blocked Y:,
/// while the mount manager of wineboot's session was still running. A later
/// build lent Y: to the installer's folder; on the next start the mount
/// manager, hearing again of whichever disc was then at `/dev/rdisk10`,
/// matched it to `y::`, took Y: and pointed `y:` at that disc's mount point.
/// The installer's folder had no letter left, so it started as a
/// `\\?\unix\` path, which Valve's Steam installer can't read itself from
/// (exit 2) and InstallShield's unpacker hung on.
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

    /// The device link Wine keeps beside `letter`'s, `y::` beside `y:`,
    /// naming the Mac disk the drive is on. Every letter the prefix doesn't
    /// use for a device has a plain file here instead, as a blocked letter
    /// has at `y:` (see "How Wine adds the Mac's disks").
    func deviceLink(_ letter: Character) -> URL {
        folder.appendingPathComponent("\(letter.lowercased())::")
    }

    /// Show `target` as `letter`, in place of whatever it showed. A relative
    /// target is kept as it is, relative to `folder`, so it still works
    /// once the prefix is copied or moved. Its device link is blocked: the
    /// folders a prefix's drives show are never a device of their own, and a
    /// device link left from a disc Wine once gave this letter would let it
    /// take the letter back for whichever disc is at that device next.
    public func mount(_ target: String, as letter: Character) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try replace(link(letter)) { try FileManager.default.createSymbolicLink(atPath: $0.path, withDestinationPath: target) }
        try blockDevice(letter)
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

    /// Every letter there is.
    static let letters = "abcdefghijklmnopqrstuvwxyz"

    /// Make `letter` show `target` and block every other letter, then take
    /// away anything else in `folder`: what `WINE.DRIVES --only=C:` makes of
    /// the prefix wineboot left, its Z: showing the whole Mac and the discs
    /// the Mac had mounted included.
    ///
    /// Each entry is replaced where it is rather than all of them removed and
    /// made again. Wine's server, and its mount manager with it, outlives
    /// wineboot for a while, and a disc it hears of while a letter has
    /// nothing at either of its names gets that letter: removing every drive
    /// before blocking them again, in order, left a late letter such as Y:
    /// empty for long enough to be taken.
    public func showOnly(_ target: String, as letter: Character) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = letter.lowercased().first ?? letter
        for each in Self.letters where each != keep {
            try blockLetter(each)
        }
        try mount(target, as: keep)
        let names = Set(Self.letters.flatMap { ["\($0):", "\($0)::"] })
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        for name in contents where !names.contains(name) {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            } catch {
                logger.warning("[Drives] Couldn't remove \(name) from \(folder.path): \(error)")
            }
        }
    }

    /// Keep Wine from giving `letters` to the Mac's own disks: a plain file
    /// at both `x:` and `x::` takes a letter out of the running in Wine's
    /// `add_drive` (see "How Wine adds the Mac's disks"). A drive already at
    /// a letter is replaced (the link, not what it shows).
    public func block(_ letters: String) {
        for letter in letters {
            do {
                try blockLetter(letter)
            } catch {
                logger.warning("[Drives] Couldn't block \(letter.uppercased()): \(error)")
            }
        }
    }

    func blockLetter(_ letter: Character) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try replace(link(letter)) { try Self.makeBlockingFile(at: $0) }
        try blockDevice(letter)
    }

    /// Put a plain file at `letter`'s device link, unless one is there
    /// already. A link there, to a disc the Mac had mounted when Wine ran,
    /// is what `add_drive` would match the next disc at that device to,
    /// taking the letter whatever `y:` shows, so it's logged as it goes.
    func blockDevice(_ letter: Character) throws {
        let device = deviceLink(letter)
        let attributes = try? FileManager.default.attributesOfItem(atPath: device.path)
        if attributes?[.type] as? FileAttributeType == .typeRegular { return }
        let stale = try? FileManager.default.destinationOfSymbolicLink(atPath: device.path)
        try replace(device) { try Self.makeBlockingFile(at: $0) }
        if let stale {
            logger.notice("[Drives] Blocked \(device.lastPathComponent), which linked to \(stale): a disk Wine gave \(letter.uppercased()): while the Mac had it mounted")
        }
    }

    /// Block every letter's device link, leaving the drives themselves be:
    /// for a prefix made before device links were blocked, which may hold
    /// one Wine wrote for a disc the Mac had mounted then.
    public func blockDevices() {
        for letter in Self.letters {
            do {
                try blockDevice(letter)
            } catch {
                logger.warning("[Drives] Couldn't block \(deviceLink(letter).lastPathComponent): \(error)")
            }
        }
    }

    /// Put what `make` makes at `entry` in a single step: it's made under a
    /// name of its own in `folder` and renamed over `entry`, which replaces
    /// a file or link in place (rename(2)), so there's never a moment with
    /// nothing at `entry`, when Wine's mount manager could take the letter
    /// for a disc. Wine only reads `dosdevices` by the drives' own names.
    func replace(_ entry: URL, make: (URL) throws -> Void) throws {
        let temporary = folder.appendingPathComponent(".\(entry.lastPathComponent)\(UUID().uuidString)")
        try make(temporary)
        if rename(temporary.path, entry.path) == 0 { return }
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        // A folder (not a link) at a drive's name can't be renamed over: that
        // one is removed first, as nothing Wine or a build makes is a folder.
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isFolder), isFolder.boolValue,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) == nil {
            try FileManager.default.removeItem(at: entry)
            if rename(temporary.path, entry.path) == 0 { return }
        }
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }

    static func makeBlockingFile(at url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// The letter `lend` shows a folder as.
    public static let lentLetter: Character = "y"

    /// Show `folder` as Y: until `takeBack()`, so a Windows program can run
    /// a file in it, and see nothing else of the Mac: an installer the
    /// person saved, or one Second Chance downloaded. Wine names a Mac path
    /// under `folder` Y:\…, as it names one under the prefix's drive_c C:\…,
    /// so the Mac path can be given as it is. That holds only while `y:`
    /// still shows `folder`: `mount` blocks `y::` so that Wine's mount
    /// manager can't take Y: back for a disc.
    public func lend(_ folder: URL) throws {
        try mount(folder, as: Self.lentLetter)
    }

    /// Block Y: again after `lend`.
    public func takeBack() {
        block(String(Self.lentLetter))
    }
}
