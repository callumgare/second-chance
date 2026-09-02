//
//  ISOMounter.swift
//  SecondChance
//
//  Mounts and unmounts ISO disk images, tracking what it mounted so it can
//  clean up later.
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

    /// Mount an ISO if it isn't already mounted, returning the mount point.
    ///
    /// - Parameters:
    ///   - isoPath: the `.iso` file to mount.
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
        process.arguments = ["attach", "-nobrowse", "-readonly", isoPath.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ISOMount", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to mount ISO: \(errorOutput)"
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
            logger.notice("   ℹ️ No mounted disk images found")
            return nil
        }

        let fileManager = FileManager.default

        // Resolve the canonical path of our ISO (in case it's a symlink)
        let canonicalISOPath: String
        if let resolved = try? fileManager.destinationOfSymbolicLink(atPath: isoPath.path) {
            canonicalISOPath = (resolved as NSString).resolvingSymlinksInPath
            logger.notice("   ℹ️ Resolved symlink: \(isoPath.path) -> \(canonicalISOPath)")
        } else {
            canonicalISOPath = (isoPath.path as NSString).resolvingSymlinksInPath
        }

        logger.notice("   ℹ️ Looking for mounted ISO: \(canonicalISOPath)")
        logger.notice("   ℹ️ Found \(images.count) mounted disk image(s)")

        // Find our ISO in the list of mounted images
        for image in images {
            guard let imagePath = image["image-path"] as? String else {
                continue
            }

            let canonicalImagePath = (imagePath as NSString).resolvingSymlinksInPath

            logger.notice("   ℹ️ Checking mounted image: \(canonicalImagePath)")

            if canonicalImagePath == canonicalISOPath {
                logger.notice("   ✓ Found matching mounted ISO")

                // Found our ISO, now get the mount points
                guard let systemEntities = image["system-entities"] as? [[String: Any]] else {
                    logger.error("   ⚠️ No system entities found for mounted ISO")
                    continue
                }

                for entity in systemEntities {
                    if let mountPoint = entity["mount-point"] as? String,
                       !mountPoint.isEmpty {
                        // Verify that the mount point actually exists as a directory
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: mountPoint, isDirectory: &isDirectory), isDirectory.boolValue {
                            logger.notice("   ✓ Mount point verified: \(mountPoint)")
                            return URL(fileURLWithPath: mountPoint)
                        } else {
                            logger.error("   ⚠️ Mount point doesn't exist or isn't a directory: \(mountPoint)")
                        }
                    }
                }
            }
        }

        logger.notice("   ℹ️ ISO not found in mounted images")
        return nil
    }
}
