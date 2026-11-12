//
//  VolumeKindsTests.swift
//  SecondChanceKitTests
//
//  What a volume is, from Disk Arbitration's description of it, and which
//  volumes a run knows.

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

    @Test("A file on the startup disk needs no volume noted")
    func startupDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("volume-kinds-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(VolumeKinds.mountPoint(of: file) == nil)
        // Nor one since removed, nor its folder.
        #expect(VolumeKinds.mountPoint(of: file.appendingPathComponent("gone/x.iso")) == nil)
    }

    @Test("The volumes mounted now are known, the startup disk's left out")
    func scan() {
        let known = VolumeKinds.known()
        #expect(known["/"] == nil)
        #expect(!known.keys.contains { $0.hasPrefix("/System/Volumes") })
        let listed = VolumeKinds.mounted().compactMap(VolumeKinds.volume).map(\.0)
        #expect(Set(listed).isSubset(of: Set(known.keys)))
    }
}
