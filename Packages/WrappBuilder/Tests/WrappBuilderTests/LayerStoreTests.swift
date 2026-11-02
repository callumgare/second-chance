//
//  LayerStoreTests.swift
//  WrappBuilderTests
//

import Foundation
import Testing
@testable import WrappBuilder

@Suite("Layer store")
struct LayerStoreTests {
    let root: URL
    let store: LayerStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("layer-store-\(UUID().uuidString)")
        store = LayerStore(root: root)
    }

    func key(_ slot: String = "wine prefix", _ inputs: [(String, String)] = [("engine", "wine 10.0_8")], parent: LayerKey? = nil) -> LayerKey {
        LayerKey(slot: slot, parent: parent, inputs: inputs.map { LayerKey.Input($0.0, $0.1) })
    }

    func write(_ text: String, to folder: URL, as name: String = "file.txt") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test func aKeysHashFollowsItsInputsAndParent() {
        #expect(key().hash == key().hash)
        #expect(key().hash != key("wine prefix", [("engine", "wine 10.0_6")]).hash)
        #expect(key("install", parent: key()).hash != key("install").hash)
        #expect(key("install", parent: key()).inputs.first == LayerKey.Input("parent", key().hash))
    }

    @Test func aMadeLayerIsFoundAndRestoredWithItsEvents() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try await store.layer(for: key()) { content in
            try write("prefix", to: content)
            return Data("[\"made\"]".utf8)
        }
        #expect(made.built)
        let again = try await store.layer(for: key()) { _ in
            Issue.record("made a layer the store has")
            return nil
        }
        #expect(!again.built)
        #expect(again.layer.events == Data("[\"made\"]".utf8))

        let destination = root.appendingPathComponent("restored/prefix")
        #expect(try store.restore(again.layer, to: destination) == .cloned)
        #expect(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8) == "prefix")
        // The clone is its own: changing it leaves the layer as it was.
        try write("changed", to: destination)
        #expect(try String(contentsOf: again.layer.content.appendingPathComponent("file.txt"), encoding: .utf8) == "prefix")
    }

    /// A8: two builds needing the same layer make it once.
    @Test func twoBuildsNeedingOneLayerMakeItOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let store = store
        let key = key()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await store.layer(for: key) { content in
                        await counter.increment()
                        // Long enough that the others are waiting for it.
                        try await Task.sleep(for: .milliseconds(200))
                        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
                        return nil
                    }.built
                }
            }
            var built = 0
            for try await wasBuilt in group where wasBuilt { built += 1 }
            #expect(built == 1)
        }
        #expect(await counter.value == 1)
    }

    @Test func aFailedMakeLeavesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        struct Failed: Error {}
        await #expect(throws: Failed.self) {
            _ = try await store.layer(for: key()) { content in
                try write("half", to: content)
                throw Failed()
            }
        }
        #expect(store.lookup(key()) == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".locks") }
        #expect(left.isEmpty)
    }

    @Test func aMissIsExplainedByWhatChanged() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = key("install", [("engine", "wine 10.0_8"), ("asset assets/disc.iss", "aaa"), ("choice variant", "wine")])
        _ = try await store.layer(for: old) { content in
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            return nil
        }
        #expect(store.explain(old) == nil)
        let new = key("install", [("engine", "wine 10.0_8"), ("asset assets/disc.iss", "bbb"), ("release installer", "2")])
        #expect(store.explain(new) == "`asset assets/disc.iss` changed (aaa → bbb), `release installer` added, `choice variant` removed")
        #expect(store.explain(key("other")) == "no other layer is cached")
    }

    @Test func pruningRemovesTheOldThenTheLeastRecentlyUsedOverTheLimit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let day: TimeInterval = 24 * 3600
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ name: String, at date: Date) async throws -> LayerKey {
            let key = key(name)
            _ = try await store.layer(for: key, now: { date }, make: { content in
                try write(String(repeating: "x", count: 100_000), to: content)
                return nil
            })
            return key
        }
        let old = try await make("old", at: start)
        let older = try await make("older", at: start.addingTimeInterval(20 * day))
        let newer = try await make("newer", at: start.addingTimeInterval(25 * day))
        let now = start.addingTimeInterval(35 * day)
        let layerSize = try #require(store.storedKeys().first?.meta.size)

        // Under the limit, only the one unused for over 30 days goes.
        #expect(store.prune(limits: .init(sizeLimit: 10 * layerSize), now: now) == [old.hash])
        // Pruned once a day at most.
        #expect(store.prune(limits: .init(sizeLimit: layerSize), now: now).isEmpty)
        // Over the limit, the least recently used goes first.
        #expect(store.prune(limits: .init(sizeLimit: layerSize), now: now, force: true) == [older.hash])
        #expect(store.lookup(newer) != nil)
    }

    @Test func aFoldersListingFollowsPathsAndSizesNotContents() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("disc")
        try write("abc", to: disc.appendingPathComponent("data"), as: "game.dat")
        let listed = try LayerKey.listing(of: disc)
        let hashed = try LayerKey.hash(folder: disc)
        try write("xyz", to: disc.appendingPathComponent("data"), as: "game.dat")
        #expect(try LayerKey.listing(of: disc) == listed)
        #expect(try LayerKey.hash(folder: disc) != hashed)
        try write("x", to: disc, as: ".DS_Store")
        #expect(try LayerKey.listing(of: disc) == listed)
        try write("abcd", to: disc.appendingPathComponent("data"), as: "game.dat")
        #expect(try LayerKey.listing(of: disc) != listed)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
