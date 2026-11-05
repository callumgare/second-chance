import Foundation
import Testing
@testable import WrappBuilder

/// Modules someone adds: imported with its checks, then loaded beside the
/// shipped ones, never in their place.
struct AddedModulesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("added-modules-\(UUID().uuidString)")

    /// A module's folder in `root`, with `module.yaml` saying `extra`.
    func module(_ id: String, _ extra: String = "") throws -> URL {
        let folder = root.appendingPathComponent("source/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
            format: 1
            id: "\(id)"
            release: 1
            versions: [{ version: "1" }]
            \(extra)
            build:
              instructions:
                COPY-TREE: { options: { into: { kind: value, role: location } }, arguments: { count: 1, roles: [input] } }
            """.write(to: folder.appendingPathComponent("module.yaml"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test("An added module is imported, then loads beside the shipped ones")
    func importsAndLoads() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let added = root.appendingPathComponent("added")
        let imported = try await AddedModules.import(try module("example/copy-tree"), shipped: modulesRoot, into: added)
        #expect(imported.manifest.id == "example/copy-tree")
        let all = try ModuleLoader(root: modulesRoot, added: added).loadAll().get()
        #expect(all.contains { $0.manifest.id == "example/copy-tree" })
        #expect(all.contains { $0.manifest.id == "wine" })
    }

    @Test("An added module's id is namespaced, and no shipped module's")
    func idRules() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let added = root.appendingPathComponent("added")
        await #expect(throws: AddedModules.Problem.self) {
            _ = try await AddedModules.import(try module("plain"), shipped: modulesRoot, into: added)
        }
        // Put there by hand, a shipped module's id is left out.
        let copy = added.appendingPathComponent("someone/wine")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try module("someone/wine"), to: copy)
        let loader = try ModuleLoader(root: modulesRoot, added: added)
        #expect(loader.addedModules(besides: []).map(\.manifest.id) == ["someone/wine"])
    }

    @Test("A program built for one architecture alone is refused, saying which is missing")
    func oneArchitecture() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try module("example/copy-tree", "program: \"bin/copy-tree\"")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ModuleProgramTests.fixture, to: folder.appendingPathComponent("bin/copy-tree"))
        await #expect {
            _ = try await AddedModules.import(folder, shipped: modulesRoot, into: root.appendingPathComponent("added"))
        } throws: { error in
            String(describing: error).contains("built without")
        }
    }
}
