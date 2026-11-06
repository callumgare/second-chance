import Foundation
@testable import GameCatalog
import Testing
@testable import WrappBuilder

/// Bundles from beyond Bundles/, which `sc --bundle` names
/// (docs/program-bundles.md#extra-bundles).
struct ExtraBundlesTests {
    /// A copy of SkiFree's bundle in a folder of no particular name, with
    /// `id` as its manifest's id.
    private func bundleCopy(id: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("extra-bundles-\(UUID().uuidString)")
            .appendingPathComponent("draft")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundlesRoot.appendingPathComponent("freeware/skifree"), to: folder)
        let manifest = folder.appendingPathComponent("manifest.yaml")
        let text = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: "id: \"freeware/skifree\"", with: "id: \"\(id)\"")
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        return folder
    }

    private func environment(_ folders: URL...) -> [String: String] {
        [ExtraBundles.environmentVariable: folders.map(\.path).joined(separator: ":")]
    }

    @Test func noneUnlessNamed() {
        #expect(ExtraBundles.folders(environment: [:]).isEmpty)
        #expect(ExtraBundles.load(shippedRoot: bundlesRoot, modules: nil, environment: [:]).isEmpty)
    }

    @Test func aBundleLoadsFromAFolderOfAnyName() throws {
        let folder = try bundleCopy(id: "test/ski-draft")
        let loaded = ExtraBundles.load(shippedRoot: bundlesRoot, modules: try shippedModules(), environment: environment(folder))
        #expect(loaded.map(\.manifest.id) == ["test/ski-draft"])
        #expect(ExtraBundles.id(of: folder) == "test/ski-draft")
    }

    @Test func itsFolderIsFoundByItsId() throws {
        let folder = try bundleCopy(id: "test/ski-draft")
        let env = environment(folder)
        #expect(ExtraBundles.folder(of: "test/ski-draft", shippedRoot: bundlesRoot, environment: env) == folder.standardizedFileURL)
        #expect(ExtraBundles.folder(of: "freeware/skifree", shippedRoot: bundlesRoot, environment: env)
            == bundlesRoot.appendingPathComponent("freeware/skifree"))
    }

    @Test func oneWithAShippedIdIsUsedInItsPlace() throws {
        let folder = try bundleCopy(id: "freeware/skifree")
        #expect(ExtraBundles.folder(of: "freeware/skifree", shippedRoot: bundlesRoot, environment: environment(folder))
            == folder.standardizedFileURL)
        let provider = GameInfoProvider()
        let before = provider.allGames().count
        ExtraBundles.addGames(shippedRoot: bundlesRoot, modules: try shippedModules(), environment: environment(folder), to: provider)
        #expect(provider.allGames().count == before)
    }

    @Test func itsGameJoinsTheCatalogue() throws {
        let folder = try bundleCopy(id: "test/ski-draft")
        let provider = GameInfoProvider()
        ExtraBundles.addGames(shippedRoot: bundlesRoot, modules: try shippedModules(), environment: environment(folder), to: provider)
        let game = provider.gameInfo(for: "ski-draft")
        #expect(game.programID == "test/ski-draft")
        #expect(game.title == "SkiFree")
        #expect(provider.allGames().last?.id == "ski-draft")
    }

    @Test func oneThatDoesNotLoadIsLeftOut() throws {
        let folder = try bundleCopy(id: "test/ski-draft")
        try "id: [".write(to: folder.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
        #expect(ExtraBundles.load(shippedRoot: bundlesRoot, modules: nil, environment: environment(folder)).isEmpty)
    }
}
