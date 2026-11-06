import Foundation
import Testing
@testable import SCKit

@Suite("The app's copies of Bundles/ and Modules/")
struct StaleAppDataTests {
    private static func tree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("A copy that matches has no difference; a changed, added or removed file is named; dotfiles don't count")
    func differences() throws {
        let base = ["freeware/icy-tower/Wrappfile": "LAUNCH a", "freeware/icy-tower/manifest.yaml": "id: x"]
        let source = try Self.tree(base.merging(["freeware/.DS_Store": "junk"]) { $1 })
        defer { try? FileManager.default.removeItem(at: source) }
        let same = try Self.tree(base)
        defer { try? FileManager.default.removeItem(at: same) }
        #expect(StaleAppData.firstDifference(source: source, copy: same) == nil)

        let edited = try Self.tree(base.merging(["freeware/icy-tower/Wrappfile": "LAUNCH b"]) { $1 })
        defer { try? FileManager.default.removeItem(at: edited) }
        #expect(StaleAppData.firstDifference(source: source, copy: edited) == "freeware/icy-tower/Wrappfile")

        let missing = try Self.tree(["freeware/icy-tower/Wrappfile": "LAUNCH a"])
        defer { try? FileManager.default.removeItem(at: missing) }
        #expect(StaleAppData.firstDifference(source: source, copy: missing) == "freeware/icy-tower/manifest.yaml")
    }

    @Test("Each folder the app copies is checked, and one the app has no copy of is left alone")
    func folders() throws {
        let checkout = try Self.tree(["Bundles/a/Wrappfile": "new", "Modules/wine/module.yaml": "id: wine"])
        defer { try? FileManager.default.removeItem(at: checkout) }
        let resources = try Self.tree(["Bundles/a/Wrappfile": "old"])
        defer { try? FileManager.default.removeItem(at: resources) }
        #expect(StaleAppData.differences(checkout: checkout, appResources: resources) == ["Bundles/a/Wrappfile"])
    }
}
