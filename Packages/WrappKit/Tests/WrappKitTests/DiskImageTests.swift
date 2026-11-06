import Foundation
@testable import ProcessKit
import Testing

@Suite("Disk images")
struct DiskImageTests {
    /// `hdiutil info -plist`'s shape: each attachment's image, owner and helper.
    static func info(_ images: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
    }

    @Test("A hung attach releases only this user's helpers for that image")
    func helpersOfImage() throws {
        let image = URL(fileURLWithPath: "/tmp/stuck.dmg")
        let plist = try Self.info([
            ["image-path": "/tmp/stuck.dmg", "owner-uid": 501, "hdid-pid": 10],
            ["image-path": "/tmp/stuck.dmg", "owner-uid": 502, "hdid-pid": 11],   // another user's
            ["image-path": "/tmp/other.dmg", "owner-uid": 501, "hdid-pid": 12],   // another image
            ["image-path": "/tmp/stuck.dmg", "owner-uid": 501],                    // no helper named
        ])
        #expect(DiskImage.helpers(of: image, infoPlist: plist, user: 501) == [10])
        #expect(DiskImage.helpers(of: image, infoPlist: Data("not a plist".utf8), user: 501).isEmpty)
    }
}
