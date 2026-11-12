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

/// The bundle folders in one of `Bundles/`'s groups (`nancy-drew`,
/// `freeware`), by name: folders only, and none hidden, so a Finder
/// `.DS_Store` beside them, which a checkout may have though git ignores
/// it, isn't taken for a bundle.
nonisolated func bundleNames(in group: String) throws -> [String] {
    let folder = bundlesRoot.appendingPathComponent(group)
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
        .sorted()
}

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

    /// A manifest with a disc edition, its installed signs and layouts as
    /// written (YAML), unchecked by the schema.
    private func manifest(id: String = "test/program", installed: String, layouts: String = "") throws -> Manifest {
        try Manifest.decode(try YAML12.load("""
        format: 1
        id: "\(id)"
        version: 1
        title: "Test"
        installed: \(installed)
        editions:
          - { id: "cd", source: "disc", build: { inputs: { disc-1: { type: "disc" } } } }
        tests:
          layouts: \(layouts.isEmpty ? "[]" : layouts)
        """))
    }

    @Test func anInstalledSignMustNameItsFile() throws {
        for glob in ["*.exe", "*", "Game/*.EXE", "?.exe"] {
            let problems = ProgramBundleLoader.installedProblems(try manifest(installed: "[{ file-exists: \"\(glob)\" }]"))
            #expect(problems.contains { $0.contains("would turn down any disc") }, "\(glob)")
        }
        for glob in ["Game.exe", "Game*.exe", "Ciftree"] {
            #expect(ProgramBundleLoader.installedProblems(try manifest(installed: "[{ file-exists: \"\(glob)\" }]")) == [], "\(glob)")
        }
    }

    @Test func aBundlesSignsAreCheckedAgainstItsOwnLayouts() throws {
        let good = try manifest(installed: "[{ file-exists: \"Game.exe\" }]", layouts: """
        [{ disc: "cd/disc-1", installer: "Setup.exe", files: ["Game/", "Setup.exe"] }, { installed: "cd", files: ["Game.exe", "Nancy.cid"] }]
        """)
        #expect(ProgramBundleLoader.installedProblems(good) == [])
        let refusesItsDisc = try manifest(installed: "[{ file-exists: \"Setup.exe\" }]", layouts: """
        [{ disc: "cd/disc-1", files: ["Setup.exe"] }]
        """)
        #expect(ProgramBundleLoader.installedProblems(refusesItsDisc) == ["its installed sign file-exists Setup.exe would turn down its own disc cd/disc-1"])
        let missesItsCopy = try manifest(installed: "[{ file-exists: \"Game.exe\" }]", layouts: """
        [{ installed: "cd", files: ["Other.exe"] }]
        """)
        #expect(ProgramBundleLoader.installedProblems(missesItsCopy) == ["none of its installed signs matches its layout installed by cd"])
        let namesNothing = try manifest(installed: "[]", layouts: """
        [{ disc: "steam/disc-1", files: [] }, { disc: "cd/disc-2", files: [] }, { installed: "big-fish", installer: "x.exe", files: [] }]
        """)
        #expect(ProgramBundleLoader.installedProblems(namesNothing) == [
            "its layout of steam/disc-1 names no disc input of a disc edition",
            "its layout of cd/disc-2 names no disc input of a disc edition",
            "its layout installed by big-fish names no edition it has",
            "its layout installed by big-fish has an installer, which only a disc's can",
        ])
    }

    @Test func aSignMustNotTurnDownAnotherBundlesDisc() throws {
        let game = try manifest(id: "test/game", installed: "[{ file-exists: \"Game.exe\" }]")
        let other = try manifest(id: "test/other", installed: "[]", layouts: """
        [{ disc: "cd/disc-1", files: ["Game.exe", "setup.exe"] }]
        """)
        #expect(ProgramBundleLoader.installedSignProblems([game, other]).map(\.description)
            == ["test/game: its installed sign file-exists Game.exe would turn down test/other's disc cd/disc-1"])
        #expect(ProgramBundleLoader.installedSignProblems([other]) == [])
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
        installed: []
        editions:
        \(editions ?? "  - { id: \"cd\", source: \"disc\", build: { inputs: { disc-1: { type: \"disc\" } } } }")

        """
        try manifest.write(to: folder.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        return folder
    }
}
