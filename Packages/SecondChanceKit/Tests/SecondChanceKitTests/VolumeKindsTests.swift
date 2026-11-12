//
//  VolumeKindsTests.swift
//  SecondChanceKitTests
//
//  What a volume is, from Disk Arbitration's description of it, and the
//  file the volumes seen are kept in.

import DiskArbitration
import Foundation
import Testing
@testable import SecondChanceKit

@Suite("Volume kinds")
struct VolumeKindsTests {
    @Test("Disk Arbitration's description says what a volume is")
    func kinds() {
        func kind(_ description: [CFString: Any], fileSystem: String = "apfs") -> VolumeKind {
            VolumeKinds.kind(description: description, fileSystem: fileSystem)
        }
        #expect(kind([kDADiskDescriptionDeviceModelKey: "Disk Image   "]) == .discImage)
        #expect(kind([kDADiskDescriptionDeviceProtocolKey: "Virtual Interface"]) == .discImage)
        #expect(kind([kDADiskDescriptionMediaKindKey: "IOCDMedia", kDADiskDescriptionDeviceInternalKey: true]) == .opticalDisc)
        #expect(kind([kDADiskDescriptionDeviceInternalKey: false], fileSystem: "cd9660") == .opticalDisc)
        #expect(kind([kDADiskDescriptionDeviceInternalKey: true]) == .internalDrive)
        #expect(kind([kDADiskDescriptionDeviceInternalKey: false]) == .externalDrive)
        #expect(kind([:]) == .unknown)
    }

    @Test("Volumes seen are kept, the old ones dropped")
    func store() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("volume-kinds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("volume-kinds.json")
        VolumeKinds.update(store: store) {
            $0["/Volumes/Old"] = MountedVolume(kind: .externalDrive, seen: Date(timeIntervalSinceNow: -VolumeKinds.maximumAge - 60))
            $0["/Volumes/Nancy Drew"] = MountedVolume(kind: .discImage, seen: Date())
        }
        let kept = VolumeKinds.load(store)
        #expect(kept["/Volumes/Nancy Drew"]?.kind == .discImage)
        #expect(kept["/Volumes/Old"] == nil)
    }

    @Test("A file on the startup disk needs no volume noted")
    func startupDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("volume-kinds-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(VolumeKinds.mountPoint(of: file) == nil)
        // Nor one since removed, nor its folder.
        #expect(VolumeKinds.mountPoint(of: file.appendingPathComponent("gone/x.iso")) == nil)
    }
}
