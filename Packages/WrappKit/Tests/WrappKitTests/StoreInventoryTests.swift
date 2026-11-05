import Foundation
import Testing
@testable import WrappFormat

@Suite("Store inventory")
struct StoreInventoryTests {
    /// Roots in a temp folder, with a global keep store (locked), an app's
    /// keep store with no record, and a global cache store.
    private func roots() throws -> (StoreLocations, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-inventory-\(UUID().uuidString)")
        let locations = StoreLocations(appSupport: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"),
                                       session: root.appendingPathComponent("session"))
        let files = FileManager.default
        let signIn = locations.folder(owner: "steam", name: "sign-in", retention: "keep", global: true, appID: "")
        try files.createDirectory(at: signIn, withIntermediateDirectories: true)
        try Data(#"{"retention":"keep","scope":"global","lock":"steam:steam"}"#.utf8)
            .write(to: signIn.deletingLastPathComponent().appendingPathComponent("sign-in.store.json"))
        try files.createDirectory(at: locations.lockFile(owner: "steam", name: "steam", global: true, appID: "").deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try files.createDirectory(at: locations.folder(owner: "app", name: "wine-documents", retention: "keep", global: false, appID: "com.example.game"),
                                  withIntermediateDirectories: true)
        try files.createDirectory(at: locations.folder(owner: "steam", name: "client", retention: "cache", global: true, appID: ""),
                                  withIntermediateDirectories: true)
        return (locations, root)
    }

    @Test("Finds the global, app and cache stores, and not the locks folder")
    func findsEach() throws {
        let (locations, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = StoreInventory.all(in: locations)
        #expect(found.map(\.fullName) == ["steam:sign-in", "app:wine-documents", "steam:client"])
        #expect(found.map(\.retention) == ["keep", "keep", "cache"])
        #expect(found.map(\.appID) == [nil, "com.example.game", nil])
        #expect(found[0].lock == "steam:steam")
        #expect(found[1].record == nil)
    }

    @Test("A store whose lock is held is in use, and free once it's let go")
    func inUse() throws {
        let (locations, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let signIn = try #require(StoreInventory.all(in: locations).first)
        let file = try #require(StoreInventory.lockFile(of: signIn, in: locations))
        #expect(file.lastPathComponent == "steam.steam.lock")
        let token = UUID()
        #expect(try ProcessLocks.tryTake(file, token: token, holder: "test"))
        #expect(StoreInventory.isInUse(signIn, in: locations))
        ProcessLocks.release(file, token: token)
        #expect(!StoreInventory.isInUse(signIn, in: locations))
    }

    @Test("Removing a store takes its record with it")
    func removes() throws {
        let (locations, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let signIn = try #require(StoreInventory.all(in: locations).first)
        try StoreInventory.remove(signIn)
        #expect(!FileManager.default.fileExists(atPath: signIn.folder.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(signIn.record).path))
        #expect(StoreInventory.all(in: locations).map(\.fullName) == ["app:wine-documents", "steam:client"])
    }
}
