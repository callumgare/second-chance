//
//  ISOMounter.swift
//  SecondChance
//
//  Mounts and unmounts disk images (game ISOs, Her Interactive's Mac
//  downloads), tracking what it mounted so it can clean up later.
//

import Foundation
import DiskArbitration
import Logging

/// Thread-safe tracker for mounted ISOs
actor MountedISOTracker {
    private var mountedISOs: Set<URL> = []

    func insert(_ url: URL) {
        mountedISOs.insert(url)
    }

    func getAll() -> Set<URL> {
        return mountedISOs
    }

    func removeAll() {
        mountedISOs.removeAll()
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
class ISOMounter {
    private let tracker = MountedISOTracker()
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ISOMounter")

    init() {}

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

    /// Mount an ISO or DMG if it isn't already mounted, returning the mount
    /// point.
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
        // Check if this ISO is already mounted
        if let existingMount = try? await findExistingMount(for: isoPath) {
            logger.notice("ISO already mounted: \(existingMount.path)")
            return existingMount
        }

        logger.notice("Mounting ISO: \(isoPath.lastPathComponent)")
        let isDMG = isoPath.pathExtension.lowercased() == "dmg"
        // stdin is empty: a DMG with a licence agreement asks for it there,
        // and is answered no rather than waited on. Her Interactive's have none.
        let attach = try await Process.output(
            of: "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly"] + (isDMG ? ["-noverify"] : []) + [isoPath.path]
        )

        guard attach.succeeded else {
            let errorOutput = (attach.output + attach.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            // hdiutil says "image not recognised" for a truncated ISO and for a
            // file that was never one; the image itself can tell them apart.
            let diagnosis = isDMG ? (.wontOpen, Self.describeSize(of: isoPath)) : Self.diagnoseImage(at: isoPath)
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
                await tracker.insert(mountURL)
                logger.notice("Mounted: \(mountURL.path)")
                return mountURL
            }
        }

        throw NSError(domain: "ISOMount", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to find mount point in hdiutil output"
        ])
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

    /// Unmount everything this mounter mounted. Safe to call when nothing is mounted.
    func unmountAll() async {
        let mountedISOs = await tracker.getAll()
        guard !mountedISOs.isEmpty else { return }

        logger.notice("Unmounting \(mountedISOs.count) ISO(s)...")

        for mountPoint in mountedISOs {
            do {
                let detach = try await Process.output(of: "/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
                if detach.succeeded {
                    logger.notice("Unmounted: \(mountPoint.path)")
                } else {
                    logger.error("Failed to unmount \(mountPoint.path) (exit code: \(detach.status))")
                }
            } catch {
                logger.error("Error unmounting \(mountPoint.path): \(error)")
            }
        }

        await tracker.removeAll()
    }

    /// Check if an ISO is already mounted and return its mount point
    private func findExistingMount(for isoPath: URL) async throws -> URL? {
        let info = try await Process.output(of: "/usr/bin/hdiutil", ["info", "-plist"])
        if !info.errorOutput.isEmpty {
            logger.critical("   hdiutil info error: \(info.errorOutput)")
        }
        let plistData = Data(info.output.utf8)

        // Parse the plist
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            logger.debug("   ℹ️ No mounted disk images found")
            return nil
        }

        let fileManager = FileManager.default

        // Resolve the canonical path of our ISO (in case it's a symlink)
        let canonicalISOPath: String
        if let resolved = try? fileManager.destinationOfSymbolicLink(atPath: isoPath.path) {
            canonicalISOPath = (resolved as NSString).resolvingSymlinksInPath
            logger.debug("   ℹ️ Resolved symlink: \(isoPath.path) -> \(canonicalISOPath)")
        } else {
            canonicalISOPath = (isoPath.path as NSString).resolvingSymlinksInPath
        }

        logger.debug("   ℹ️ Looking for mounted ISO: \(canonicalISOPath)")
        logger.debug("   ℹ️ Found \(images.count) mounted disk image(s)")

        // Find our ISO in the list of mounted images
        for image in images {
            guard let imagePath = image["image-path"] as? String else {
                continue
            }

            let canonicalImagePath = (imagePath as NSString).resolvingSymlinksInPath

            logger.debug("   ℹ️ Checking mounted image: \(canonicalImagePath)")

            if canonicalImagePath == canonicalISOPath {
                logger.debug("   ✓ Found matching mounted ISO")

                // Found our ISO, now get the mount points
                guard let systemEntities = image["system-entities"] as? [[String: Any]] else {
                    logger.warning("   ⚠️ No system entities found for mounted ISO")
                    continue
                }

                for entity in systemEntities {
                    if let mountPoint = entity["mount-point"] as? String,
                       !mountPoint.isEmpty {
                        // Verify that the mount point actually exists as a directory
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: mountPoint, isDirectory: &isDirectory), isDirectory.boolValue {
                            logger.debug("   ✓ Mount point verified: \(mountPoint)")
                            return URL(fileURLWithPath: mountPoint)
                        } else {
                            logger.warning("   ⚠️ Mount point doesn't exist or isn't a directory: \(mountPoint)")
                        }
                    }
                }
            }
        }

        logger.debug("   ℹ️ ISO not found in mounted images")
        return nil
    }
}
