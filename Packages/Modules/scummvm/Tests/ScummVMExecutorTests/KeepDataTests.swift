import Foundation
import Testing
@testable import ScummVMExecutor
import WrappModuleKit

/// SCUMMVM.KEEP-DATA: a game's app keeps the engine data it needs.
struct KeepDataTests {
    /// A stage's tree with ScummVM's engine in it, as `EngineInstall` lays
    /// one in, and a bundle's icon beside its data.
    private func tree() throws -> URL {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("keep-data-\(UUID().uuidString)/stage.app")
        let resources = tree.appendingPathComponent("Contents/Resources")
        let engine = ["MacOS/scummvm", "Resources/nancy.dat", "Resources/lure.dat", "Resources/classicmacfonts.dat",
                      "Resources/shaders.dat", "Resources/shaders/crt.glslp", "Resources/gui-icons.dat",
                      "Resources/translations.dat", "Resources/licenses/GPL.txt", "Resources/COPYRIGHT",
                      "Resources/engines/scummvm.files"]
        for path in engine + ["Resources/nancy-drew.icns"] {
            let file = tree.appendingPathComponent("Contents").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
        }
        try Data((engine.joined(separator: "\n") + "\n").utf8).write(to: resources.appendingPathComponent("engines/scummvm.files"))
        return tree
    }

    private func exists(_ path: String, in tree: URL) -> Bool {
        FileManager.default.fileExists(atPath: tree.appendingPathComponent("Contents/\(path)").path)
    }

    @Test func keepsWhatItIsToldAndWhatScummVMNeeds() throws {
        let tree = try tree()
        let removed = try ScummVMExecutor.keep(["nancy.dat"], in: tree)
        #expect(removed == ["classicmacfonts.dat", "lure.dat"])
        for kept in ["Resources/nancy.dat", "Resources/shaders.dat", "Resources/shaders/crt.glslp", "Resources/gui-icons.dat",
                     "Resources/translations.dat", "Resources/licenses/GPL.txt", "Resources/COPYRIGHT", "MacOS/scummvm"] {
            #expect(exists(kept, in: tree), "\(kept) was taken out")
        }
        #expect(!exists("Resources/lure.dat", in: tree) && !exists("Resources/classicmacfonts.dat", in: tree))
    }

    @Test func leavesTheBundlesOwnFiles() throws {
        let tree = try tree()
        _ = try ScummVMExecutor.keep(["nancy.dat"], in: tree)
        #expect(exists("Resources/nancy-drew.icns", in: tree))
        #expect(exists("Resources/engines/scummvm.files", in: tree))
    }

    @Test func itsListNoLongerNamesWhatWentOut() throws {
        let tree = try tree()
        _ = try ScummVMExecutor.keep(["nancy.dat"], in: tree)
        let list = try String(contentsOf: tree.appendingPathComponent(ScummVMExecutor.listPath), encoding: .utf8)
        #expect(!list.contains("lure.dat") && list.contains("Resources/nancy.dat") && list.contains("MacOS/scummvm"))
    }

    @Test func aFileTheEngineDoesNotHaveFails() throws {
        let tree = try tree()
        #expect(throws: StepFailure.self) { try ScummVMExecutor.keep(["nancy.dat", "nonexistent.dat"], in: tree) }
        #expect(exists("Resources/lure.dat", in: tree), "took files out before failing")
    }

    @Test func aStageWithoutScummVMFails() throws {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("keep-data-\(UUID().uuidString)/stage.app")
        #expect(throws: StepFailure.self) { try ScummVMExecutor.keep(["nancy.dat"], in: tree) }
    }
}
