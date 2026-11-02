import Foundation
import GameCatalog
import SecondChanceKit
import Testing
@testable import SecondChance
import WrappBuilder

/// Each game's Wrappfile says what its builder does today: the same discs,
/// installer options, answer files and patches the builders work out from
/// `GameInfo`, the bundle's assets and `GamePatchCatalog`. Until the
/// Wrappfile builder runs them, this is what keeps the two from drifting.
@MainActor
struct WrappfileTodayTests {
    nonisolated static let games = GameInfoProvider.shared.allGames()

    private func wrappfile(_ game: GameInfo) throws -> Wrappfile {
        let file = TestPaths.repoRoot.appendingPathComponent("Bundles/nancy-drew/\(game.id)/Wrappfile")
        return try WrappfileParser.parse(String(contentsOf: file, encoding: .utf8))
    }

    private func instructions(_ file: Wrappfile, stage: String) throws -> [Instruction] {
        try #require(file.stage(named: stage), "no \(stage) stage").body.flatMap(\.instructions)
    }

    private func patchIDs(_ instructions: [Instruction]) -> [String] {
        instructions.filter { $0.keyword == "DO" && $0.arguments.first?.raw == "nancy-drew.patch" }
            .compactMap { $0.option("id")?.value?.raw }
    }

    @Test("The disc edition keeps the discs, installs and patches as the disc builder does", arguments: games)
    func discEditionIsTodays(_ game: GameInfo) throws {
        let file = try wrappfile(game)
        let steps = try instructions(file, stage: "disc")
        let keep = try #require(steps.first { $0.keyword == "wine.KEEP-DISCS" })
        #expect((keep.option("combined") != nil) == (game.diskCount > 1))

        let installs = steps.filter { $0.keyword == "installer.RUN" }
        if game.gameEngine == .scummvm {
            #expect(installs.isEmpty, "ScummVM reads the disc's data; nothing is installed")
            #expect(steps.contains { $0.keyword == "USE" && $0.arguments.first?.raw == "scummvm" })
        } else {
            let install = try #require(installs.first)
            #expect(installs.count == 1)
            #expect((install.option("stubborn") != nil) == game.doesNotExitInNonInteractiveMode)
            #expect((install.option("answer-file") != nil) == (ShippedBundles.asset("disc.iss", ofGame: game.id) != nil))
            let exeFolder = try #require(game.internalGameExePath.map { "C:" + ($0 as NSString).deletingLastPathComponent })
            #expect(file.globalArgs.first { $0.name == "install-dir" }?.value?.raw == exeFolder)
        }
        let patches = GamePatchCatalog.shared.automaticPatches(forGame: game.id, source: .disk).map(\.id)
        #expect(patchIDs(steps) == patches)
    }

    @Test("Her download's edition installs and patches as the Her download builder does", arguments: games)
    func herDownloadEditionIsTodays(_ game: GameInfo) throws {
        let steps = try instructions(try wrappfile(game), stage: "her-download")
        let install = try #require(steps.first { $0.keyword == "her-download.INSTALL" })
        #expect((install.option("answer-file") != nil) == (ShippedBundles.asset("her-download.iss", ofGame: game.id) != nil))
        let patches = GamePatchCatalog.shared.automaticPatches(forGame: game.id, source: .herDownload).map(\.id)
        #expect(patchIDs(steps) == patches)
    }
}
