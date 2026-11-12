//
//  VolumeKinds.swift
//  SecondChanceKit
//
//  What each volume a path may be on is — a disc image, a real disc, a
//  drive, a network share — so a report can keep what's on a disc and
//  redact a drive's name and folders (`PathRedactor`). That can only be
//  asked while the volume is mounted, and a report may come after it's gone
//  (a build detaches its images). So every volume mounted when Second
//  Chance or a wrapp starts is looked at then, and each path the person
//  chooses, and each image we mount, adds its volume as it comes. It's kept
//  in memory only, for this run: a crash reported at the next start goes by
//  what's mounted at that start.
//
//  docs/failure-reports.md ("Volumes") has why.

import DiskArbitration
import Foundation
import os

/// What a volume is, as far as what a report keeps of a path on it.
nonisolated public enum VolumeKind: String, Sendable {
    case discImage = "disc-image"
    case opticalDisc = "optical-disc"
    case internalDrive = "internal-drive"
    case externalDrive = "external-drive"
    case networkDrive = "network-drive"
    case unknown
}

/// A volume, as seen while it was mounted.
nonisolated public struct MountedVolume: Sendable, Equatable {
    public var kind: VolumeKind
    /// Where a network drive is mounted from: `//user@host/share`.
    public var source: String?

    public init(kind: VolumeKind, source: String? = nil) {
        self.kind = kind
        self.source = source
    }
}

nonisolated public enum VolumeKinds {
    private struct State {
        var volumes: [String: MountedVolume] = [:]
        var scanned = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Look at every volume mounted now, in the background: called once, as
    /// Second Chance or a wrapp starts, beside starting failure reports.
    public static func start() {
        Task.detached { scan() }
    }

    /// Note the volume `url` is on, in the background: a path the person
    /// chose, or an image we mounted. Nothing is noted for the startup disk.
    /// At the default priority: it's quick, and a lower one could wait out a
    /// build on a fully loaded Mac and be lost to the failure it was for.
    public static func note(_ url: URL) {
        Task.detached { record(url) }
    }

    /// `note`, done now.
    public static func record(_ url: URL) {
        guard let info = fileSystem(of: url), let (mountPoint, volume) = volume(info) else { return }
        state.withLock { $0.volumes[mountPoint] = volume }
    }

    /// Every volume known in this run, by mount point. A report sent before
    /// the start's look has finished (a crash from the previous run) looks
    /// for itself.
    public static func known() -> [String: MountedVolume] {
        if !state.withLock({ $0.scanned }) { scan() }
        return state.withLock { $0.volumes }
    }

    static func scan() {
        let found = mounted().compactMap(volume)
        state.withLock { state in
            for (mountPoint, volume) in found { state.volumes[mountPoint] = volume }
            state.scanned = true
        }
    }

    // MARK: Asking macOS

    /// Every mount, from the kernel's own list without asking any of them
    /// (`MNT_NOWAIT`), so a network share that has gone away can't hold it up.
    static func mounted() -> [statfs] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableBufferPointer<statfs>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let size = Int32(MemoryLayout<statfs>.stride * buffer.count)
        let filled = getfsstat(buffer.baseAddress, size, MNT_NOWAIT)
        return Array(buffer.prefix(Int(max(filled, 0))))
    }

    /// The file system `url` is on, or that of the nearest folder above it
    /// still there (a file since removed).
    static func fileSystem(of url: URL) -> statfs? {
        var path = url.standardizedFileURL.path
        var info = statfs()
        while statfs(path, &info) != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { return nil }
            path = parent
        }
        return info
    }

    /// The mount point of the volume `url` is on, or nil for the startup
    /// disk (whose paths need no volume to be told).
    static func mountPoint(of url: URL) -> String? {
        guard let info = fileSystem(of: url) else { return nil }
        let mountPoint = string(info.f_mntonname)
        return isSystemMount(mountPoint) ? nil : mountPoint
    }

    static func isSystemMount(_ mountPoint: String) -> Bool {
        mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes") || mountPoint == "/dev" || mountPoint.hasPrefix("/private/var/vm")
    }

    /// What the volume `info` describes is: a network one by its file
    /// system; otherwise Disk Arbitration says (a disk image, a disc's
    /// media, an internal or external drive). Nil for the startup disk's.
    static func volume(_ info: statfs) -> (String, MountedVolume)? {
        let mountPoint = string(info.f_mntonname)
        guard !isSystemMount(mountPoint) else { return nil }
        let fileSystem = string(info.f_fstypename)
        if ["autofs", "devfs"].contains(fileSystem) { return nil }
        if ["smbfs", "afpfs", "nfs", "webdav", "ftp", "cifs"].contains(fileSystem) || info.f_flags & UInt32(MNT_LOCAL) == 0 {
            return (mountPoint, MountedVolume(kind: .networkDrive, source: string(info.f_mntfromname)))
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: mountPoint) as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else {
            // No disk behind it: a CD's file system still says what it is.
            let kind: VolumeKind = ["cd9660", "udf", "cddafs"].contains(fileSystem) ? .opticalDisc : .unknown
            return (mountPoint, MountedVolume(kind: kind))
        }
        return (mountPoint, MountedVolume(kind: kind(description: description, fileSystem: fileSystem)))
    }

    static func kind(description: [CFString: Any], fileSystem: String) -> VolumeKind {
        let model = (description[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces)
        let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey] as? String
        if model == "Disk Image" || deviceProtocol == "Virtual Interface" { return .discImage }
        let media = description[kDADiskDescriptionMediaKindKey] as? String
        if ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(media) || ["cd9660", "cddafs"].contains(fileSystem) {
            return .opticalDisc
        }
        if let isInternal = description[kDADiskDescriptionDeviceInternalKey] as? Bool {
            return isInternal ? .internalDrive : .externalDrive
        }
        return .unknown
    }

    /// A C string field of `statfs` as a String.
    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
