//
//  ISOMounter.swift
//  SecondChance
//
//  Mounts and unmounts disk images (game ISOs, Her Interactive's Mac
//  downloads), tracking what it mounted so it can clean up later.
//

import Foundation
import SecondChanceKit
import DiskArbitration
import Logging

/// Thread-safe tracker for mounted ISOs
actor MountedISOTracker {
    struct Mount {
        /// The image it's a mount of.
        let image: URL
        /// A hybrid disc's ISO 9660 side mounted by hand: the device hdiutil
        /// attached it as, which must be unmounted first.
        let device: String?
        /// The shadow file that made it a copy of its own (`ISOMounter.mount`).
        let shadow: URL
    }

    private var mounts: [URL: Mount] = [:]

    func insert(_ mountPoint: URL, image: URL, device: String? = nil, shadow: URL) {
        mounts[mountPoint] = Mount(image: image, device: device, shadow: shadow)
    }

    func getAll() -> [URL: Mount] {
        mounts
    }

    /// Where this mounter already mounted `image`, if it has.
    func mountPoint(of image: URL) -> URL? {
        let wanted = image.resolvingSymlinksInPath().path
        return mounts.first { $0.value.image.resolvingSymlinksInPath().path == wanted }?.key
    }

    func removeAll() {
        mounts.removeAll()
    }
}

/// Why a disc image or a Mac download wouldn't mount. Each case is its own
/// kind in a failure report, which says nothing more: why hdiutil turned it
/// down is in the log.
nonisolated enum DiscImageError: LocalizedError, Equatable {
    /// Shorter than its own header says: a download or copy that didn't finish.
    case incomplete
    /// A raw copy of a CD (a BIN, often renamed .iso), which a Mac can't mount.
    case rawCDImage
    /// No ISO 9660 header: not a copy of a CD at all.
    case notADiscImage
    /// It looks whole, but hdiutil turned it down anyway.
    case wontOpen

    var errorDescription: String? {
        switch self {
        case .incomplete:
            return String(localized: "That file is only part of a game disc: it may not have finished downloading or copying. Copy it again, then try again.")
        case .rawCDImage:
            return String(localized: "That file is a copy of a game disc in a form a Mac can't open. Choose the game's disc instead.")
        case .notADiscImage:
            return String(localized: "That file isn't a copy of a game disc. Choose the game's disc instead.")
        case .wontOpen:
            return String(localized: "Your Mac couldn't open that file. If you downloaded it, try downloading it again.")
        }
    }
}

/// Mounts game ISOs via hdiutil and unmounts everything it mounted.
///
/// Owns the mounted-ISO tracking. The caller decides when mounting and
/// unmounting happen — typically mount up front, `unmountAll()` on both the
/// success and error paths of the enclosing build flow.
///
/// Every mount is this mounter's own, never one already there: a plain
/// `hdiutil attach` of an image that's attached hands back that attachment,
/// so two builds of one disc at once (in two test users' sessions) shared it,
/// and the first to finish detached it from under the other. With a shadow
/// file the same image attaches again as a device of its own (writes, of
/// which a read-only mount makes none, would go to the shadow), mounted in
/// a folder of this mounter's own under the volume's name, which detection
/// reads.
class ISOMounter {
    private let tracker = MountedISOTracker()
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ISOMounter")
    /// Where this mounter's volumes are mounted, and their shadow files kept.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("second-chance-discs-\(UUID().uuidString.prefix(8))")

    init() {}

    /// What `hdiutil attach` is given to attach `image` as a copy of its own,
    /// its shadow file in `root`, mounted (unless `mount` is false) in `root`
    /// under the volume's name.
    nonisolated static func attachOptions(dmg: Bool, root: URL, shadow: URL, mount: Bool = true) -> [String] {
        var options = ["-readonly", "-shadow", shadow.path]
        options += mount ? ["-nobrowse", "-mountroot", root.path] : ["-nomount"]
        if dmg || !mount { options.append("-noverify") }
        return options
    }

    private func newShadow() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(UUID().uuidString.prefix(8)).shadow")
    }

    /// Whether the volume at `url` is a mounted disk image (an ISO or DMG)
    /// rather than a real disc: Disk Arbitration names a disk image's device
    /// model "Disk Image".
    static func isDiskImageVolume(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return (description[kDADiskDescriptionDeviceModelKey] as? String)?
            .trimmingCharacters(in: .whitespaces) == "Disk Image"
    }

    /// Mount an ISO or DMG as a copy of this mounter's own (or return the
    /// one it already made of that image), returning the mount point.
    ///
    /// A DMG is mounted without hdiutil's checksum pass, which takes more
    /// than half a minute for a 1 GB download; what is then read from it
    /// (a gzipped archive, for the Her Interactive Mac downloads) is checked
    /// as it is read.
    ///
    /// Anything other than a `.dmg` is taken to be a CD image, whatever its
    /// name: one that won't mount throws a `DiscImageError` saying why.
    ///
    /// - Parameter isoPath: the disc image or `.dmg` file to mount.
    /// - Returns: the mounted volume's URL.
    func mount(_ isoPath: URL) async throws -> URL {
        if let mounted = await tracker.mountPoint(of: isoPath) {
            logger.notice("ISO already mounted by this build: \(mounted.path)")
            return mounted
        }

        logger.notice("Mounting ISO: \(isoPath.lastPathComponent)")
        let isDMG = isoPath.pathExtension.lowercased() == "dmg"
        let shadow = try newShadow()
        // stdin is empty: a DMG with a licence agreement asks for it there,
        // and is answered no rather than waited on. Her Interactive's have none.
        // Bounded: an attach that hangs is stopped and the image released
        // (`DiskImage`), rather than holding the build and the Mac's disk service.
        let attach = try await DiskImage.attach(isoPath, options: Self.attachOptions(dmg: isDMG, root: root, shadow: shadow))

        guard attach.succeeded else {
            let errorOutput = (attach.output + attach.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            // hdiutil says "image not recognised" for a truncated ISO and for a
            // file that was never one; the image itself can tell them apart.
            let diagnosis = isDMG ? (.wontOpen, Self.describeSize(of: isoPath)) : Self.diagnoseImage(at: isoPath)
            try? FileManager.default.removeItem(at: shadow)
            if diagnosis.problem == .wontOpen, !isDMG, let hybrid = await mountISOSide(of: isoPath) {
                logger.notice("hdiutil couldn't mount \(isoPath.lastPathComponent) (\(errorOutput)); mounted its ISO 9660 side instead")
                return hybrid
            }
            logger.error("hdiutil couldn't attach \(isoPath.path): \(errorOutput) — \(diagnosis.description)")
            throw diagnosis.problem
        }
        let output = attach.output

        // Find the mount point in the output (last column, usually /Volumes/...)
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let mountPoint = parts.last, mountPoint.hasPrefix("/") {
                let mountURL = URL(fileURLWithPath: mountPoint)

                // Track that we mounted this
                await tracker.insert(mountURL, image: isoPath, shadow: shadow)
                logger.notice("Mounted: \(mountURL.path)")
                return mountURL
            }
        }

        throw NSError(domain: "ISOMount", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to find mount point in hdiutil output"
        ])
    }

    /// A hybrid Mac and PC disc's ISO 9660 side. Its Apple partition map
    /// leads hdiutil to look only at its HFS partition, which macOS can no
    /// longer mount, and refuse the image ("no mountable file systems"),
    /// though the ISO 9660 side, the one Windows reads, is whole. So the
    /// image is attached without mounting, and its whole device mounted as
    /// ISO 9660 in a folder of its own. Nil, with everything undone, when
    /// that fails too.
    private func mountISOSide(of isoPath: URL) async -> URL? {
        do {
            let shadow = try newShadow()
            let attach = try await DiskImage.attach(isoPath, options: Self.attachOptions(dmg: false, root: root, shadow: shadow, mount: false))
            guard attach.succeeded,
                  let device = attach.output.split(separator: "\n").first?
                      .split(whereSeparator: \.isWhitespace).first.map(String.init),
                  device.hasPrefix("/dev/disk") else {
                logger.error("Couldn't attach \(isoPath.lastPathComponent) without mounting it: \(attach.errorOutput)")
                try? FileManager.default.removeItem(at: shadow)
                return nil
            }
            let mountPoint = root.appendingPathComponent("disc-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let mount = try await Process.output(
                of: "/sbin/mount", ["-t", "cd9660", "-o", "rdonly,nobrowse", device, mountPoint.path])
            guard mount.succeeded else {
                logger.error("Couldn't mount \(device) as ISO 9660: \(mount.errorOutput)")
                _ = try? await Process.output(of: "/usr/bin/hdiutil", ["detach", device, "-quiet"])
                try? FileManager.default.removeItem(at: mountPoint)
                try? FileManager.default.removeItem(at: shadow)
                return nil
            }
            await tracker.insert(mountPoint, image: isoPath, device: device, shadow: shadow)
            logger.notice("Mounted: \(mountPoint.path) (\(device), ISO 9660)")
            return mountPoint
        } catch {
            logger.error("Couldn't mount \(isoPath.lastPathComponent)'s ISO 9660 side: \(error)")
            return nil
        }
    }

    /// A DMG has no header to check its size against, so only its size.
    nonisolated static func describeSize(of url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return "it is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    /// What an ISO 9660 image's own header says about why it wouldn't
    /// mount: its size against the size its primary volume descriptor
    /// declares, or that it has none — the problem for the person, and a
    /// description for the log.
    nonisolated static func diagnoseImage(at url: URL) -> (problem: DiscImageError, description: String) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (.wontOpen, "the file can't be read (\(sizeText))")
        }
        defer { try? handle.close() }
        // A raw image (a BIN, often renamed .iso) keeps every sector's 2352
        // bytes, starting with the CD sync pattern, which hdiutil can't read.
        let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
        if let start = try? handle.read(upToCount: sync.count), start.elementsEqual(sync) {
            return (.rawCDImage, "it is \(sizeText) and a raw CD image (2352-byte sectors, a BIN), which hdiutil can't mount")
        }
        // The primary volume descriptor is sector 16 of 2048-byte sectors.
        let descriptorOffset: UInt64 = 16 * 2048
        guard (try? handle.seek(toOffset: descriptorOffset)) != nil,
              let descriptor = try? handle.read(upToCount: 2048), descriptor.count == 2048,
              descriptor[1...5].elementsEqual("CD001".utf8) else {
            return (.notADiscImage,
                    "it is \(sizeText) and has no ISO 9660 header, so it isn't a CD image (or is cut off before its first 34 KB)")
        }
        func uint32LE(_ offset: Int) -> Int64 {
            descriptor[offset..<(offset + 4)].reversed().reduce(Int64(0)) { $0 << 8 | Int64($1) }
        }
        func uint16LE(_ offset: Int) -> Int64 {
            Int64(descriptor[offset]) | Int64(descriptor[offset + 1]) << 8
        }
        let declared = uint32LE(80) * uint16LE(128)
        let declaredText = ByteCountFormatter.string(fromByteCount: declared, countStyle: .file)
        if declared > 0 && size < declared {
            return (.incomplete,
                    "it is truncated: \(sizeText) of the \(declaredText) its header declares (an incomplete download or copy)")
        }
        return (.wontOpen, "it is a \(sizeText) ISO 9660 image whose header declares \(declaredText)")
    }

    /// Unmount everything this mounter mounted, and remove its shadow files
    /// and folder. Safe to call when nothing is mounted.
    func unmountAll() async {
        let mounted = await tracker.getAll()
        guard !mounted.isEmpty else { return }

        logger.notice("Unmounting \(mounted.count) ISO(s)...")

        for (mountPoint, mount) in mounted {
            do {
                // A hybrid disc's ISO side was mounted by hand: its device
                // stays busy until that mount goes.
                if mount.device != nil {
                    let unmount = try await Process.output(of: "/sbin/umount", [mountPoint.path])
                    if !unmount.succeeded {
                        logger.error("Failed to unmount \(mountPoint.path): \(unmount.errorOutput)")
                    }
                }
                let detach = try await Process.output(of: "/usr/bin/hdiutil", ["detach", mount.device ?? mountPoint.path, "-quiet"])
                if mount.device != nil {
                    do {
                        try FileManager.default.removeItem(at: mountPoint)
                    } catch {
                        logger.warning("Couldn't remove the empty mount point \(mountPoint.path): \(error)")
                    }
                }
                if detach.succeeded {
                    logger.notice("Unmounted: \(mountPoint.path)")
                    // Kept while attached: the copy reads through it.
                    do {
                        try FileManager.default.removeItem(at: mount.shadow)
                    } catch {
                        logger.warning("Couldn't remove the shadow file \(mount.shadow.path): \(error)")
                    }
                } else {
                    logger.error("Failed to unmount \(mountPoint.path) (exit code: \(detach.status))")
                }
            } catch {
                logger.error("Error unmounting \(mountPoint.path): \(error)")
            }
        }

        await tracker.removeAll()
        // Only once it's empty: a folder still holding a mount is never removed.
        if (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
