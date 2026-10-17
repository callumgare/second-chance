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

@Suite("Game patch catalog")
struct GamePatchCatalogTests {

    /// The manifest as it sits in the source tree, so these tests do not
    /// depend on a build having staged it into a bundle.
    private static var sourceManifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SecondChanceTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("WrappTemplate/game-patches.json")
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
        let scripts = Self.sourceManifestURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SecondChance/Resources/patch-automation")
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

    // MARK: - Edition matching

    @Test("Edition 'any' applies to every source")
    func anyEditionMatchesAll() {
        for source in WrappSource.allCases {
            #expect(GamePatch.Edition.any.matches(source))
        }
    }

    @Test("CD patches apply only to disk builds")
    func cdEdition() {
        #expect(GamePatch.Edition.cd.matches(.disk))
        #expect(!GamePatch.Edition.cd.matches(.herDownload))
        #expect(!GamePatch.Edition.cd.matches(.steam))
    }

    @Test("Digital-download patches apply to download and Steam builds")
    func downloadEdition() {
        #expect(!GamePatch.Edition.digitalDownload.matches(.disk))
        #expect(GamePatch.Edition.digitalDownload.matches(.herDownload))
        #expect(GamePatch.Edition.digitalDownload.matches(.steam))
    }

    /// Castle Malloy is the clearest case of a game whose CD and
    /// digital-download patches must never both be applied.
    @Test("A game with CD and download patches picks exactly one per source")
    func editionSplitPicksOne() {
        let catalog = catalog()
        let fromDisk = catalog.automaticPatches(forGame: "castle-malloy", source: .disk)
        let fromDownload = catalog.automaticPatches(forGame: "castle-malloy", source: .herDownload)

        #expect(fromDisk.count == 1)
        #expect(fromDownload.count == 1)
        #expect(fromDisk.first?.id != fromDownload.first?.id)
    }

    // MARK: - Automatic vs optional

    @Test("Puzzle solvers are never applied automatically")
    func solversAreOptional() {
        let catalog = catalog()
        let automaticIDs = Set(
            catalog.patchedGameSlugs
                .flatMap { catalog.automaticPatches(forGame: $0, source: .disk) }
                .map(\.id)
        )
        // Her Interactive explicitly tells players not to install these
        // unless they are stuck.
        for solver in ["haunted-mansion-bird-inlay-solver", "ghost-dogs-cola-solver", "deception-island-clamming"] {
            #expect(!automaticIDs.contains(solver), "\(solver) should not apply automatically")
        }
    }

    @Test("Automatic and optional partition the patches for a game")
    func partition() {
        let catalog = catalog()
        for slug in catalog.patchedGameSlugs {
            for source in WrappSource.allCases {
                let auto = catalog.automaticPatches(forGame: slug, source: source)
                let optional = catalog.optionalPatches(forGame: slug, source: source)
                let all = catalog.allPatches(forGame: slug)

                #expect(auto.count + optional.count == all.count)
                #expect(Set(auto.map(\.id)).isDisjoint(with: Set(optional.map(\.id))))
            }
        }
    }

    @Test("White Wolf never applies the superseded 1.0.1 updater automatically")
    func supersededUpdaterIsOptional() {
        let catalog = catalog()
        for source in WrappSource.allCases {
            let ids = catalog.automaticPatches(forGame: "white-wolf", source: source).map(\.id)
            #expect(!ids.contains("white-wolf-isis-command-box"))
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
