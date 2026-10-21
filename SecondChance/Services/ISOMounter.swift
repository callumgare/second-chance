//
//  ISOMounter.swift
//  SecondChance
//
//  Mounts and unmounts disk images (game ISOs, Her Interactive's Mac
//  downloads), tracking what it mounted so it can clean up later.
//

import Foundation
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

/// Mounts game ISOs via hdiutil and unmounts everything it mounted.
///
/// Owns the mounted-ISO tracking. The caller decides when mounting and
/// unmounting happen — typically mount up front, `unmountAll()` on both the
/// success and error paths of the enclosing build flow.
class ISOMounter {
    private let tracker = MountedISOTracker()
    private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.ISOMounter")

    init() {}

    /// Mount an ISO or DMG if it isn't already mounted, returning the mount
    /// point.
    ///
    /// A DMG is mounted without hdiutil's checksum pass, which takes more
    /// than half a minute for a 1 GB download; what is then read from it
    /// (a gzipped archive, for the Her Interactive Mac downloads) is checked
    /// as it is read.
    ///
    /// - Parameters:
    ///   - isoPath: the `.iso` or `.dmg` file to mount.
    ///   - requestAccess: closure the mounter invokes with the raw mount point
    ///     so sandboxed callers can prompt for volume access (or skip straight
    ///     through when access was granted some other way). Returning the URL
    ///     unchanged is the no-op default.
    /// - Returns: the mounted volume's URL (verified accessible).
    func mount(
        _ isoPath: URL,
        requestAccess: @Sendable (URL) async throws -> URL = { $0 }
    ) async throws -> URL {
        // Check if this ISO is already mounted
        if let existingMount = try? await findExistingMount(for: isoPath) {
            logger.notice("ISO already mounted: \(existingMount.path)")
            return existingMount
        }

        logger.notice("Mounting ISO: \(isoPath.lastPathComponent)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let isDMG = isoPath.pathExtension.lowercased() == "dmg"
        process.arguments = ["attach", "-nobrowse", "-readonly"] + (isDMG ? ["-noverify"] : []) + [isoPath.path]
        // A DMG with a licence agreement asks for it on stdin: answer no
        // rather than wait for ever. Her Interactive's have none.
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = (String(data: data, encoding: .utf8) ?? "Unknown error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // hdiutil says "image not recognised" for a truncated ISO and for a
            // file that was never one; the image itself can tell them apart.
            let diagnosis = isDMG ? Self.describeSize(of: isoPath) : Self.diagnoseImage(at: isoPath)
            logger.error("hdiutil couldn't attach \(isoPath.path): \(errorOutput) — \(diagnosis)")
            throw NSError(domain: "ISOMount", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to mount \(isoPath.lastPathComponent): \(errorOutput). \(diagnosis)"
            ])
        }

        // Parse hdiutil output to get mount point
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ISOMount", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read mount output"
            ])
        }

        // Find the mount point in the output (last column, usually /Volumes/...)
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let mountPoint = parts.last, mountPoint.hasPrefix("/") {
                var mountURL = URL(fileURLWithPath: mountPoint)

                // For sandboxed apps, may need user to grant access
                mountURL = try await requestAccess(mountURL)

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

    /// What an ISO 9660 image's own header says about it: its size against
    /// the size its primary volume descriptor declares, or that it has none.
    nonisolated static func diagnoseImage(at url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "the file can't be read (\(sizeText))"
        }
        defer { try? handle.close() }
        // The primary volume descriptor is sector 16 of 2048-byte sectors.
        let descriptorOffset: UInt64 = 16 * 2048
        guard (try? handle.seek(toOffset: descriptorOffset)) != nil,
              let descriptor = try? handle.read(upToCount: 2048), descriptor.count == 2048,
              descriptor[1...5].elementsEqual("CD001".utf8) else {
            return "it is \(sizeText) and has no ISO 9660 header, so it isn't a CD image (or is cut off before its first 34 KB)"
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
            return "it is truncated: \(sizeText) of the \(declaredText) its header declares (an incomplete download or copy)"
        }
        return "it is a \(sizeText) ISO 9660 image whose header declares \(declaredText)"
    }

    /// Unmount everything this mounter mounted. Safe to call when nothing is mounted.
    func unmountAll() async {
        let mountedISOs = await tracker.getAll()
        guard !mountedISOs.isEmpty else { return }

        logger.notice("Unmounting \(mountedISOs.count) ISO(s)...")

        for mountPoint in mountedISOs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", mountPoint.path, "-quiet"]

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    logger.notice("Unmounted: \(mountPoint.path)")
                } else {
                    logger.error("Failed to unmount \(mountPoint.path) (exit code: \(process.terminationStatus))")
                }
            } catch {
                logger.error("Error unmounting \(mountPoint.path): \(error)")
            }
        }

        await tracker.removeAll()
    }

    /// Check if an ISO is already mounted and return its mount point
    private func findExistingMount(for isoPath: URL) async throws -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Print any errors to console
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
            logger.critical("   hdiutil info error: \(errorOutput)")
        }

        let plistData = outputPipe.fileHandleForReading.readDataToEndOfFile()

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
