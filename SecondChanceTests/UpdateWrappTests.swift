//
//  UpdateWrappTests.swift
//  SecondChanceTests
//
//  What updating an old wrapp works out from it, before anything runs.

import Foundation
import Testing
import GameCatalog
import WrappBuilder
@testable import SecondChance
@testable import SecondChanceKit

@Suite("Updating a wrapp")
struct UpdateWrappTests {
    /// A wrapp from before locks: its settings and Wine's version file, as
    /// Second Chance's earlier releases left them.
    private func oldWrapp(slug: String, exe: String, wine: String = "wine sikarugir 10.0 (revision 8)\n",
                          source: WrappSource? = nil) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateWrappTests-\(UUID().uuidString)/\(slug).app")
        let layout = WrappLayout(app: app)
        try WrappSettings(gameExePath: exe, engine: .wine, gameSlug: slug, source: source,
                          installerDir: "/nancy-drew-installer/disk-1").write(to: layout)
        try FileManager.default.createDirectory(at: layout.wine, withIntermediateDirectories: true)
        try wine.write(to: layout.wine.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        return app
    }

    @Test func aGamesAppIsToldFromADisc() throws {
        let app = try oldWrapp(slug: "old-clock", exe: "/Program Files/Nancy Drew/Secret of the Old Clock/Game.exe")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(UpdateWrappBuilder.isWrapp(app))
        #expect(!UpdateWrappBuilder.isWrapp(app.deletingLastPathComponent()))
    }

    @Test func aWrappFromBeforeLocksGetsOneMadeUp() throws {
        let app = try oldWrapp(slug: "old-clock", exe: "/Program Files/Nancy Drew/Secret of the Old Clock/Game.exe")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let (lock, _) = try UpdateWrappBuilder.lock(of: app)
        #expect(lock.madeUp == true)
        #expect(lock.bundle == .init(id: "nancy-drew/old-clock", version: 0))
        #expect(lock.edition == "cd")
        #expect(lock.modules.first { $0.id == "wine" }?.version == "10.0_8")
    }

    @Test func anOldWrappOnThisWineIsUpdatedWithoutItsDisc() throws {
        // Old Clock's Wrappfile installs to the folder the wrapp has, so
        // only the prefix set-up, recorded nowhere in a made-up lock, needs
        // doing again.
        let plan = try #require(try ShippedBundles.plan(forGame: "old-clock", edition: "cd"))
        _ = plan
        let app = try oldWrapp(slug: "old-clock", exe: try installDir(of: "old-clock") + "/Game.exe")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let (lock, settings) = try UpdateWrappBuilder.lock(of: app)
        let (decision, target) = try ShippedBundles.updateDecision(from: lock, forGame: "old-clock", source: .disk,
                                                                   composition: settings.composition)
        guard case .update(let chain) = decision else {
            Issue.record("expected an update, got \(decision)")
            return
        }
        #expect(chain.applied == ["wine-prefix"])
        #expect(chain.moves.isEmpty)
        #expect(target.modules.first { $0.id == "wine" }?.files?["prefix.yaml"] != nil)
        #expect(target.args?["install-dir"] != nil)
    }

    @Test func anOldWrappOnAnotherMajorWineNeedsItsDisc() throws {
        let app = try oldWrapp(slug: "old-clock", exe: try installDir(of: "old-clock") + "/Game.exe", wine: "wine-9.0 (revision 2)\n")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let (lock, settings) = try UpdateWrappBuilder.lock(of: app)
        let (decision, _) = try ShippedBundles.updateDecision(from: lock, forGame: "old-clock", source: .disk,
                                                              composition: settings.composition)
        guard case .freshBuild = decision else {
            Issue.record("Wine 9 to 10 should need the disc, got \(decision)")
            return
        }
    }

    @Test func theNeedForTheDiscIsSaidPlainly() {
        let message = WrappBuildError.updateNeedsSource(reason: "its wine 9.0_2 can't be moved").playerMessage
        #expect(message.contains("disc"))
        #expect(!message.contains("wine"))
        let steam = WrappBuildError.updateNeedsSource(reason: "the steam update builds it afresh", source: .steam).playerMessage
        #expect(steam.contains("Steam") && !steam.contains("disc"))
    }

    /// The game's folder as its lock records it, `C:` dropped: where the
    /// wrapp's settings put its exe.
    private func installDir(of slug: String) throws -> String {
        let lock = try ShippedBundles.lock(forGame: slug, edition: "cd", source: .disk,
                                           composition: GameInfoProvider.shared.gameInfo(for: slug).composition)
        let dir = try #require(lock.args?["install-dir"])
        return String(dir.dropFirst(2))
    }
}
