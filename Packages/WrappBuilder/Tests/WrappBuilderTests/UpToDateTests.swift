import Foundation
import Testing
import WrappFormat
import WrappModules
@testable import WrappBuilder

/// When an update has nothing to do: no update applies, and the wrapp has
/// this build's launcher and engines.
struct UpToDateTests {
    private func planner() throws -> UpdatePlanner {
        let manifest = try Manifest.decode([
            "format": 1, "id": "nancy-drew/example", "version": 3, "title": "Example",
            "editions": [["id": "cd", "source": "disc", "build": ["target": "disc"]]],
        ] as [String: Any])
        let wine = try Manifest.decodeKebab(ModuleManifest.self, from: [
            "format": 1, "id": "wine", "release": 4, "versions": [["version": "10.0_8"]],
            "updates": [["id": "wine-prefix", "when-changed": ["stages/prefix"]]],
        ] as [String: Any])
        return UpdatePlanner(manifest: manifest, modules: [ModuleFolder(folder: URL(fileURLWithPath: "/modules/wine"), manifest: wine)]) { _ in
            ["wine"]
        }
    }

    private func wine(package: String?) -> WrappLock.ModuleRef {
        .init(id: "wine", release: 4, version: "10.0_8", files: ["stages/prefix": "same"], package: package)
    }

    private func target(launcher: String? = "launcher-1", package: String = "engine-1") -> UpdatePlanner.Target {
        .init(bundleVersion: 3, edition: "cd", modules: [wine(package: package)], launch: nil, launcher: launcher)
    }

    private func lock(launcher: String? = "launcher-1", package: String? = "engine-1") -> WrappLock {
        var lock = WrappLock(bundle: .init(id: "nancy-drew/example", version: 3), edition: "cd", source: "disk",
                             composition: Composition(launcher: .wine), modules: [wine(package: package)], builtBy: "1.0.0")
        lock.launcher = launcher
        return lock
    }

    @Test("A wrapp with this build's launcher and engines, and no update to apply, is up to date")
    func upToDate() throws {
        #expect(try planner().plan(old: lock(), target: target()) == .upToDate)
    }

    @Test("Another launcher is brought: an update with nothing else to apply")
    func newLauncher() throws {
        #expect(try planner().plan(old: lock(launcher: "launcher-0"), target: target())
            == .update(.init(applied: [], steps: [], previous: ["bundle": "3", "edition": "cd", "wine": "10.0_8"], moves: [])))
    }

    @Test("A wrapp from before launchers were recorded is brought this one")
    func unrecordedLauncher() throws {
        guard case .update = try planner().plan(old: lock(launcher: nil), target: target()) else {
            Issue.record("expected an update")
            return
        }
    }

    @Test("Another package of the same engine version is brought, with no prefix move")
    func newEnginePackage() throws {
        guard case .update(let chain) = try planner().plan(old: lock(package: "engine-0"), target: target()) else {
            Issue.record("expected an update")
            return
        }
        #expect(chain.moves.isEmpty)
    }

    @Test("A build that doesn't know its own launcher never says a wrapp is up to date")
    func unknownLauncher() throws {
        guard case .update = try planner().plan(old: lock(launcher: nil), target: target(launcher: nil)) else {
            Issue.record("expected an update")
            return
        }
    }
}
