//
//  GamePatchCatalogTests.swift
//  SecondChanceTests
//
//  Exercises the game-patch manifest and the catalog that reads it.
//
//  The manifest is data, so most of the risk is data being wrong in ways the
//  compiler cannot see: a game slug that matches no known game means the
//  patch is downloaded, bundled, and then silently never applied.
//

import Testing
import Foundation
@testable import SecondChance
import GameCatalog
import SecondChanceKit

@Suite("Game patch catalog")
@MainActor
struct GamePatchCatalogTests {

    /// The manifest as it sits in the source tree, so these tests do not
    /// depend on a build having staged it into a bundle.
    private static var sourceManifestURL: URL {
        TestPaths.repoRoot.appendingPathComponent("Modules/nancy-drew/patches.json")
    }

    private func catalog() -> GamePatchCatalog {
        GamePatchCatalog(manifestURL: Self.sourceManifestURL)
    }

    // MARK: - Manifest integrity

    @Test("Manifest parses and is not empty")
    func manifestParses() {
        #expect(!catalog().isEmpty)
    }

    @Test("Every patched game slug matches a known game")
    func slugsAreReal() {
        let known = Set(GameInfoProvider.shared.allGames().map(\.id))
        for slug in catalog().patchedGameSlugs {
            #expect(known.contains(slug), "Manifest references unknown game slug '\(slug)'")
        }
    }

    @Test("Patch ids are unique")
    func idsAreUnique() {
        let catalog = catalog()
        let all = catalog.patchedGameSlugs.flatMap { catalog.allPatches(forGame: $0) }
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test("Every patch names an archive, a payload and an https source")
    func fieldsArePopulated() {
        let catalog = catalog()
        for slug in catalog.patchedGameSlugs {
            for patch in catalog.allPatches(forGame: slug) {
                #expect(!patch.archive.isEmpty)
                #expect(!patch.payload.isEmpty)
                #expect(patch.url.hasPrefix("https://"), "\(patch.id) has a non-https url")
            }
        }
    }

    @Test("Only patches that copy or extract files name a destination subdirectory")
    func destinationOnlyForCopies() {
        let catalog = catalog()
        for slug in catalog.patchedGameSlugs {
            for patch in catalog.allPatches(forGame: slug) where patch.action == .runInstaller {
                #expect(patch.destinationSubdirectory == nil, "\(patch.id) is an installer but names a destination")
            }
        }
    }

    @Test("Every automated patch is an installer whose AutoIt script exists")
    func automationScriptsExist() {
        // The manifest's own module's scripts.
        let scripts = Self.sourceManifestURL.deletingLastPathComponent().appendingPathComponent("assets")
        let catalog = catalog()
        for slug in catalog.patchedGameSlugs {
            for patch in catalog.allPatches(forGame: slug) {
                guard let automation = patch.automation else { continue }
                #expect(patch.action == .runInstaller, "\(patch.id) is automated but isn't an installer")
                let script = scripts.appendingPathComponent("\(automation).au3")
                #expect(FileManager.default.fileExists(atPath: script.path), "\(patch.id) names \(automation).au3, which doesn't exist")
            }
        }
    }

    // MARK: - Which apply

    /// Each Nancy Drew game's patches, for its disc and Her download
    /// editions, as `patches.json`'s automatic and edition fields chose them
    /// before they went: what the Wrappfiles' patch steps are checked against.
    nonisolated static let editionPatches: [String: [String: [String]]] = {
        // The repo `sc` names, not this file's path when compiled: an
        // integration run on another Mac of a build made here found none.
        let url = TestPaths.repoRoot.appendingPathComponent("TestFixtures/edition-patches.json")
        struct Fixture: Decodable { let games: [String: [String: [String]]] }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode(Fixture.self, from: data).games) ?? [:]
    }()

    @Test("The fixture names only patches the catalogue has, each for its own game")
    func fixtureIsTheCatalogues() throws {
        #expect(!Self.editionPatches.isEmpty)
        let catalog = catalog()
        for (game, editions) in Self.editionPatches {
            let ids = Set(catalog.allPatches(forGame: game).map(\.id))
            for patch in editions.values.flatMap({ $0 }) {
                #expect(ids.contains(patch), "\(patch) isn't one of \(game)'s patches")
            }
        }
    }

    /// Castle Malloy is the clearest case of a game whose CD and
    /// digital-download patches must never both be applied.
    @Test("A game with CD and download patches applies exactly one per edition")
    func editionSplitPicksOne() {
        let castle = Self.editionPatches["castle-malloy"] ?? [:]
        #expect(castle["disc"]?.count == 1)
        #expect(castle["her-download"]?.count == 1)
        #expect(castle["disc"] != castle["her-download"])
    }

    @Test("Puzzle solvers and the superseded updater are never applied")
    func solversAreLeftOut() {
        let applied = Set(Self.editionPatches.values.flatMap { $0.values.flatMap { $0 } })
        // Her Interactive tells players not to install these unless they are stuck.
        for patch in ["haunted-mansion-bird-inlay-solver", "ghost-dogs-cola-solver", "deception-island-clamming",
                      "white-wolf-isis-command-box"] {
            #expect(!applied.contains(patch), "\(patch) shouldn't be applied")
        }
    }

    // MARK: - Missing manifest

    @Test("A missing manifest yields an empty catalog rather than throwing")
    func missingManifestIsEmpty() {
        let catalog = GamePatchCatalog(
            manifestURL: URL(fileURLWithPath: "/nonexistent/game-patches.json")
        )
        #expect(catalog.isEmpty)
        #expect(catalog.allPatches(forGame: "castle-malloy").isEmpty)
    }
}
