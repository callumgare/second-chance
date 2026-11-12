//
//  VolumeKinds.swift
//  SecondChanceKit
//
//  What each volume a path was on is — a disc image, a real disc, a drive,
//  a network share — so a report can keep what's on a disc and redact a
//  drive's name and folders (`PathRedactor`). That can only be asked while
//  the volume is mounted, and a report may come long after: a build
//  detaches its images, and a crash is reported at the next start. So each
//  path the person chooses, and each image we mount, notes its volume here,
//  kept in a file the next run reads.
//
//  docs/failure-reports.md ("Volumes") has why.

import DiskArbitration
import Foundation
import Logging
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.VolumeKinds")

/// What a volume is, as far as what a report keeps of a path on it.
nonisolated public enum VolumeKind: String, Codable, Sendable {
    case discImage = "disc-image"
    case opticalDisc = "optical-disc"
    case internalDrive = "internal-drive"
    case externalDrive = "external-drive"
    case networkDrive = "network-drive"
    case unknown
}

/// A volume, as seen while it was mounted.
nonisolated public struct MountedVolume: Codable, Sendable, Equatable {
    public var kind: VolumeKind
    /// Where a network drive is mounted from: `//user@host/share`.
    public var source: String?
    /// When it was last seen, so old entries can go.
    public var seen: Date?

    public init(kind: VolumeKind, source: String? = nil, seen: Date? = nil) {
        self.kind = kind
        self.source = source
        self.seen = seen
    }
}

nonisolated public enum VolumeKinds {
    /// Where what's been seen is kept, for every Second Chance process.
    public static var storeFile: URL {
        StoreLocations.realAppSupport.appendingPathComponent("SecondChance/volume-kinds.json")
    }

    /// Entries older than this are dropped, as are the oldest beyond `limit`.
    static let maximumAge: TimeInterval = 180 * 24 * 3600
    static let limit = 200

    /// Note the volume `url` is on, in the background: a path the person
    /// chose, or an image we mounted. Nothing is noted for the startup disk.
    /// At the default priority: it's quick, and a lower one could wait out a
    /// build on a fully loaded Mac and be lost to the failure it was for.
    public static func note(_ url: URL) {
        Task.detached { record(url) }
    }

    /// `note`, done now.
    public static func record(_ url: URL, store: URL = storeFile) {
        guard let mountPoint = mountPoint(of: url), let volume = probe(mountPoint: mountPoint) else { return }
        update(store: store) { $0[mountPoint] = volume }
    }

    /// Every volume known: those noted before, and those mounted now, as
    /// they are now.
    public static func known(store: URL = storeFile) -> [String: MountedVolume] {
        var volumes = load(store)
        for mountPoint in mountedNow() {
            if let volume = probe(mountPoint: mountPoint) { volumes[mountPoint] = volume }
        }
        return volumes
    }

    // MARK: Asking macOS

    /// The mount point of the volume `url` is on, or nil for the startup
    /// disk (whose paths need no volume to be told).
    static func mountPoint(of url: URL) -> String? {
        var path = url.standardizedFileURL.path
        var info = statfs()
        // A file since removed: ask about the nearest folder still there.
        while statfs(path, &info) != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { return nil }
            path = parent
        }
        let mountPoint = withUnsafePointer(to: info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return isSystemMount(mountPoint) ? nil : mountPoint
    }

    static func isSystemMount(_ mountPoint: String) -> Bool {
        mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes") || mountPoint == "/dev" || mountPoint.hasPrefix("/private/var/vm")
    }

    static func mountedNow() -> [String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return urls.map(\.path).filter { !isSystemMount($0) }
    }

    /// What the volume mounted at `mountPoint` is: from its file system
    /// (a network one, a CD's), then Disk Arbitration (a disk image, a
    /// disc's media, an internal or external drive).
    public static func probe(mountPoint: String) -> MountedVolume? {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else { return nil }
        let fileSystem = withUnsafePointer(to: info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let source = withUnsafePointer(to: info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let now = Date()
        if ["smbfs", "afpfs", "nfs", "webdav", "ftp", "cifs"].contains(fileSystem) || info.f_flags & UInt32(MNT_LOCAL) == 0 {
            return MountedVolume(kind: .networkDrive, source: source, seen: now)
        }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: mountPoint) as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else {
            // No disk behind it: a CD's file system still says what it is.
            let kind: VolumeKind = ["cd9660", "udf", "cddafs"].contains(fileSystem) ? .opticalDisc : .unknown
            return MountedVolume(kind: kind, seen: now)
        }
        return MountedVolume(kind: kind(description: description, fileSystem: fileSystem), seen: now)
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

    // MARK: The file

    static func load(_ store: URL) -> [String: MountedVolume] {
        guard let data = try? Data(contentsOf: store) else { return [:] }
        do {
            return try JSONDecoder().decode([String: MountedVolume].self, from: data)
        } catch {
            logger.warning("Couldn't read the volumes seen before, starting afresh: \(error)")
            return [:]
        }
    }

    static func update(store: URL, _ change: (inout [String: MountedVolume]) -> Void) {
        var volumes = load(store)
        change(&volumes)
        let cutoff = Date().addingTimeInterval(-maximumAge)
        volumes = volumes.filter { ($0.value.seen ?? .distantPast) > cutoff }
        if volumes.count > limit {
            let newest = volumes.sorted { ($0.value.seen ?? .distantPast) > ($1.value.seen ?? .distantPast) }.prefix(limit)
            volumes = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        do {
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(volumes).write(to: store, options: .atomic)
        } catch {
            logger.warning("Couldn't keep the volumes seen: \(error)")
        }
    }
}
