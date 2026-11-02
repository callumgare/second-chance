import Foundation
import Testing
@testable import WrappBuilder

nonisolated let modulesRoot = repoRoot.appendingPathComponent("Modules")

struct ModuleDataTests {
    @Test func everyModuleIsValidAndItsReleaseRecorded() throws {
        let loader = try ModuleLoader(root: modulesRoot)
        let modules = try loader.loadAll().get()
        #expect(modules.map(\.manifest.id).sorted() == ["disc", "her-download", "installer", "nancy-drew", "scummvm", "steam", "wine"])
        let releases = try ModuleReleases.read(from: modulesRoot.appendingPathComponent("releases.json"))
        for module in modules {
            #expect(try releases.problems(with: module) == [], "\(module.manifest.id)")
        }
    }

    @Test func theGeneratedSwiftIsWhatTheDataMakes() throws {
        for (path, generated) in try ModuleDataSource.generatedFiles(modules: try ModuleLoader(root: modulesRoot)) {
            let checkedIn = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(generated == checkedIn, "\(path) is stale: run `sc generate`")
        }
    }

    @Test func aChangedModuleNeedsANewRelease() throws {
        let (loader, folder) = try temporaryModule()
        var releases = ModuleReleases()
        try releases.record(try #require(loader.module("demo")))
        try "changed".write(to: folder.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        let problems = try releases.problems(with: try #require(loader.module("demo")))
        #expect(problems.count == 1)
        #expect(problems.first?.contains("has changed since release 1 was recorded (extra.txt)") == true)
        #expect(throws: ModuleReleases.RecordError.self) { try releases.record(try #require(loader.module("demo"))) }
    }

    @Test func aReleaseMayNotDropWhatAVersionHad() throws {
        let previous = ModuleReleases.Release(release: 1, versions: ["1"], functions: ["functions/patch"], data: ["patches.yaml"], files: [:])
        let next = ModuleReleases.Release(release: 2, versions: ["1"], functions: [], data: ["patches.yaml"], files: [:])
        #expect(ModuleReleases.compatibilityProblems(from: previous, to: next).count == 1)
        // A new version may drop it.
        let newVersion = ModuleReleases.Release(release: 2, versions: ["2"], functions: [], data: [], files: [:])
        #expect(ModuleReleases.compatibilityProblems(from: previous, to: newVersion).isEmpty)
    }

    /// A modules folder with the schema and one module, `demo`.
    private func temporaryModule() throws -> (ModuleLoader, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: modulesRoot.appendingPathComponent("module.schema.json"),
                                         to: root.appendingPathComponent("module.schema.json"))
        try """
        format: 1
        id: "demo"
        release: 1
        versions: [{ version: "1" }]

        """.write(to: folder.appendingPathComponent("module.yaml"), atomically: true, encoding: .utf8)
        return (try ModuleLoader(root: root), folder)
    }
}
