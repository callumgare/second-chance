import Foundation
import Synchronization
import Testing
@testable import WrappBuilder

struct EngineStoreTests {
    /// A store in a folder of its own, and an engine module whose package
    /// names `hash`, prepared by a stand-in that writes one file and counts
    /// how often it runs.
    private func fixture(hash: String = String(repeating: "a", count: 64), makes made: String? = nil,
                         prepare: (@Sendable (URL) async throws -> Void)? = nil) throws -> (EngineStore, ModuleFolder, Counter, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-store-\(UUID().uuidString)")
        let modules = root.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("demo"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: modulesRoot.appendingPathComponent("module.schema.json"),
                                         to: modules.appendingPathComponent("module.schema.json"))
        try """
        format: 1
        id: "demo"
        release: 1
        versions:
          - version: "1"
            package:
              prepared: "\(hash)"
              sources: [{ id: "demo", sha256: "\(String(repeating: "b", count: 64))", urls: ["https://example.invalid/demo"] }]

        """.write(to: modules.appendingPathComponent("demo/module.yaml"), atomically: true, encoding: .utf8)
        let module = try #require(try ModuleLoader(root: modules).module("demo"))
        let runs = Counter()
        let store = EngineStore(root: root.appendingPathComponent("engines")) { module, _, tree, _ in
            runs.add()
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("SharedSupport"), withIntermediateDirectories: true)
            try Data("engine".utf8).write(to: tree.appendingPathComponent("SharedSupport/engine"))
            try await prepare?(tree)
            try EngineTree.writeList(module: module.manifest.id, in: tree)
            return made ?? hash
        }
        return (store, module, runs, root)
    }

    nonisolated final class Counter: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    @Test("An engine is prepared once, then found by its hash")
    func preparedOnce() async throws {
        let (store, module, runs, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.engine(module)
        #expect(first.prepared)
        #expect(FileManager.default.fileExists(atPath: first.tree.appendingPathComponent("SharedSupport/engine").path))
        let second = try await store.engine(module)
        #expect(!second.prepared)
        #expect(second.tree == first.tree)
        #expect(runs.value == 1)
    }

    @Test("Builds asking for the same engine at once wait for the one preparing it")
    func preparedOnceAtOnce() async throws {
        let (store, module, runs, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let engines = try await withThrowingTaskGroup(of: EngineStore.Engine.self) { group in
            for _ in 0..<4 { group.addTask { try await store.engine(module) } }
            var engines: [EngineStore.Engine] = []
            while let engine = try await group.next() { engines.append(engine) }
            return engines
        }
        #expect(runs.value == 1)
        #expect(engines.filter(\.prepared).count == 1)
    }

    @Test("A tree missing a listed file is prepared again")
    func shortTree() async throws {
        let (store, module, runs, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await store.engine(module)
        try FileManager.default.removeItem(at: engine.tree.appendingPathComponent("SharedSupport/engine"))
        #expect(try await store.engine(module).prepared)
        #expect(runs.value == 2)
    }

    @Test("A preparation that gives another hash fails, and leaves nothing behind")
    func wrongHash() async throws {
        let (store, module, _, root) = try fixture(makes: String(repeating: "c", count: 64))
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: EngineError.self) { try await store.engine(module) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0 != ".locks" } == [])
    }

    @Test("Pruning keeps what the modules list and what is being prepared, and removes the rest")
    func prune() async throws {
        let (store, module, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try await store.engine(module)
        let old = store.folder(String(repeating: "d", count: 64))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let stopped = store.root.appendingPathComponent(".incoming-\(String(repeating: "e", count: 64))-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stopped, withIntermediateDirectories: true)
        let preparing = String(repeating: "f", count: 64)
        let going = store.root.appendingPathComponent(".incoming-\(preparing)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: going, withIntermediateDirectories: true)
        let lock = try #require(LayerStore.tryLock(store.lockFile(preparing)))
        defer { lock.release() }

        let removed = try store.prune(keeping: EngineStore.listedHashes(in: [module]))
        #expect(removed == [String(repeating: "d", count: 64)])
        #expect(FileManager.default.fileExists(atPath: kept.tree.path))
        #expect(!FileManager.default.fileExists(atPath: stopped.path))
        #expect(FileManager.default.fileExists(atPath: going.path))
    }

    @Test("A version whose package names no prepared hash can't be stored")
    func noHash() async throws {
        let (store, module, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = module.file("module.yaml")
        let text = try String(contentsOf: yaml, encoding: .utf8)
        try text.replacingOccurrences(of: "      prepared: \"\(String(repeating: "a", count: 64))\"\n", with: "")
            .write(to: yaml, atomically: true, encoding: .utf8)
        let unhashed = try #require(try ModuleLoader(root: module.folder.deletingLastPathComponent()).module("demo"))
        await #expect(throws: EngineError.self) { try await store.engine(unhashed) }
    }
}
