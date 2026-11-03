import Foundation
import GameCatalog
import SecondChanceKit
import Testing
@testable import SecondChance
import WrappBuilder

/// Each game's Wrappfile says what its builder does today: the same discs,
/// installer options, answer files and patches the builders work out from
/// `GameInfo`, the bundle's assets and the patches each edition applies
/// (`TestFixtures/edition-patches.json`). Until the
/// Wrappfile builder runs them, this is what keeps the two from drifting.
@MainActor
struct WrappfileTodayTests {
    /// The Nancy Drew games, whose builders came before their Wrappfiles.
    nonisolated static let games = GameInfoProvider.shared.allGames().filter { $0.series == "Nancy Drew" }

    private func wrappfile(_ game: GameInfo) throws -> Wrappfile {
        let file = TestPaths.repoRoot.appendingPathComponent("Bundles/nancy-drew/\(game.id)/Wrappfile")
        return try WrappfileParser.parse(String(contentsOf: file, encoding: .utf8))
    }

    /// A target's instructions, and those of the `<target>-files` stage its
    /// data is copied from, for a ScummVM game whose data needs Wine.
    private func instructions(_ file: Wrappfile, stage: String) throws -> [Instruction] {
        let files = file.stage(named: stage + "-files")?.body.flatMap(\.instructions) ?? []
        return try files + #require(file.stage(named: stage), "no \(stage) stage").body.flatMap(\.instructions)
    }

    private func patchIDs(_ instructions: [Instruction]) -> [String] {
        instructions.filter { $0.keyword == "DO" && $0.arguments.first?.raw == "nancy-drew.patch" }
            .compactMap { $0.option("id")?.value?.raw }
    }

    @Test("The disc edition keeps the discs, installs and patches as the disc builder does", arguments: games)
    func discEditionIsTodays(_ game: GameInfo) throws {
        let file = try wrappfile(game)
        let steps = try instructions(file, stage: "disc")
        let installs = steps.filter { $0.keyword == "INSTALLER.RUN" }
        if game.gameEngine == .scummvm {
            // ScummVM reads the disc's data, copied into the app: through Wine
            // only to patch it, otherwise as it is.
            #expect(installs.isEmpty, "ScummVM reads the disc's data; nothing is installed")
            #expect(file.stage(named: "disc")?.from == .stage("scummvm"))
            let keeps = steps.contains { $0.keyword == "WINE.KEEP-DISCS" }
            #expect(keeps == (file.stage(named: "disc-files") != nil))
        } else {
            let keep = try #require(steps.first { $0.keyword == "WINE.KEEP-DISCS" })
            #expect((keep.option("combined") != nil) == (game.diskCount > 1))
            let install = try #require(installs.first)
            #expect(installs.count == 1)
            #expect((install.option("answer-file") != nil) == (ShippedBundles.asset("disc.iss", ofGame: game.id) != nil))
            let exeFolder = try #require(game.internalGameExePath.map { "C:" + ($0 as NSString).deletingLastPathComponent })
            let installDir = file.globals.compactMap(Declaration.init).first { $0.kind == .const && $0.name == "install-dir" }
            #expect(installDir?.value?.raw == exeFolder)
        }
        let patches = GamePatchCatalogTests.editionPatches[game.id]?["disc"] ?? []
        #expect(patchIDs(steps) == patches)
    }

    @Test("Her download's edition installs and patches as the Her download builder does", arguments: games)
    func herDownloadEditionIsTodays(_ game: GameInfo) throws {
        let steps = try instructions(try wrappfile(game), stage: "her-download")
        let install = try #require(steps.first { $0.keyword == "HER-DOWNLOAD.INSTALL" })
        #expect((install.option("answer-file") != nil) == (ShippedBundles.asset("her-download.iss", ofGame: game.id) != nil))
        let patches = GamePatchCatalogTests.editionPatches[game.id]?["her-download"] ?? []
        #expect(patchIDs(steps) == patches)
    }

    /// Every bundle, loaded once: checking them runs ajv, which is too slow
    /// to do for each game on the main actor.
    nonisolated static let bundles: [String: ProgramBundle] = {
        let root = TestPaths.repoRoot
        guard let modules = try? ModuleLoader(root: root.appendingPathComponent("Modules")).loadAll().get(),
              let all = try? ProgramBundleLoader(root: root.appendingPathComponent("Bundles"), modules: modules).loadAll().get()
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.manifest.name, $0) })
    }()

    /// The games Her also sold for the Mac.
    nonisolated static let herMacGames = games.filter { game in
        let manifest = TestPaths.repoRoot.appendingPathComponent("Bundles/nancy-drew/\(game.id)/manifest.yaml")
        return (try? String(contentsOf: manifest, encoding: .utf8))?.contains("id: \"her-mac\"") == true
    }

    @Test("Her's Mac download takes the game out of the Cider app and patches nothing", arguments: herMacGames)
    func herMacEditionIsTodays(_ game: GameInfo) throws {
        let steps = try instructions(try wrappfile(game), stage: "her-mac")
        #expect(steps.contains { $0.keyword == "HER-DOWNLOAD.INSTALL" })
        #expect(patchIDs(steps).isEmpty)
    }

    @Test("Steam's launch mode is a choice exactly where today's Steam build asks it", arguments: games)
    func steamLaunchModeIsAChoice(_ game: GameInfo) throws {
        let bundle = try #require(Self.bundles[game.id])
        let steam = bundle.manifest.editions.first { $0.source == .steam }
        let choice = steam?.choice("launch-mode")
        #expect((choice != nil) == game.offersSteamLaunchChoice)
        if let choice {
            #expect(choice.options == ["direct", "steam"])
            #expect(choice.default == "direct", "a headless build launches directly")
        }
    }
}
