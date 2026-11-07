import Foundation
import BigFishKit
import DOSBoxKit
import GameCatalog
import ScummVMKit
import Testing
import WineKit
import WrappModules
@testable import WrappBuilder

/// The repo's root, from this file's place in it.
nonisolated let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
nonisolated let bundlesRoot = repoRoot.appendingPathComponent("Bundles")

/// Where the shipped modules' paths are: their kits', as a host gives them.
nonisolated let shippedPlaces = PathPlaces([WinePaths.self, DOSBoxPaths.self, ScummVMPaths.self, BigFishPaths.self])

/// Every module in the repo's Modules/.
nonisolated func shippedModules() throws -> [ModuleFolder] {
    try ModuleLoader(root: repoRoot.appendingPathComponent("Modules")).loadAll().get()
}

struct ProgramBundleTests {
    @Test func everyBundleIsValid() throws {
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let folders = try loader.bundleFolders()
        #expect(folders.count >= 33)
        for folder in folders {
            if case .failure(let problems) = loader.load(folder) {
                Issue.record("\(problems)")
            }
        }
    }

    @Test func theCatalogueIsWhatTheBundlesMake() throws {
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let bundles = try loader.loadAll().get()
        let generated = GameCatalogSource.source(for: try GameCatalogSource.games(from: bundles, modules: try shippedModules(), places: shippedPlaces))
        let checkedIn = try String(contentsOf: repoRoot.appendingPathComponent(GameCatalogSource.path), encoding: .utf8)
        #expect(generated == checkedIn, "\(GameCatalogSource.path) is stale: run `sc generate`")
    }

    @Test("A program's engine in the catalogue is its launcher's: Basilisk II's is basilisk, not Wine")
    func catalogueEnginesFollowTheLauncher() throws {
        #expect(GameCatalogSource.engine(of: .basilisk) == .basilisk)
        #expect(GameCatalogSource.engine(of: .scummvm) == .scummvm)
        #expect(GameCatalogSource.engine(of: .dosbox) == .dosbox)
        #expect(GameCatalogSource.engine(of: .wine) == .wine)
        #expect(GameCatalogSource.engine(of: nil) == .wine)
        let ingenious = try #require(GameInfoProvider.shared.allGames().first { $0.id == "ingenious" })
        #expect(ingenious.gameEngine == .basilisk)
        #expect(!ingenious.gameEngine.runsInWine)
    }

    @Test func theCatalogueRoundTripsThroughTheSourceItIsMadeOf() throws {
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let games = try GameCatalogSource.games(from: try loader.loadAll().get(), modules: try shippedModules(), places: shippedPlaces)
        #expect(games == GameInfoProvider.shared.allGames())
    }

    @Test func aFolderMustMatchItsId() throws {
        let folder = try temporaryBundle(id: "nancy-drew/elsewhere", in: "nancy-drew/old-clock")
        let loader = try ProgramBundleLoader(root: folder.deletingLastPathComponent().deletingLastPathComponent(), modules: [])
        guard case .failure(let problems) = loader.load(folder) else {
            Issue.record("loaded a bundle in the wrong folder")
            return
        }
        #expect(problems.description.contains("its folder says nancy-drew/old-clock"))
    }

    /// A copy of the schema and one bundle in a folder of its own, with
    /// `id` as the manifest's id.
    private func temporaryBundle(id: String, in path: String, editions: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundlesRoot.appendingPathComponent("manifest.schema.json"),
                                         to: root.appendingPathComponent("manifest.schema.json"))
        let manifest = """
        format: 1
        id: "\(id)"
        version: 1
        title: "Test"
        editions:
        \(editions ?? "  - { id: \"cd\", source: \"disc\", build: { inputs: { disc-1: { type: \"disc\" } } } }")

        """
        try manifest.write(to: folder.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        return folder
    }
}
