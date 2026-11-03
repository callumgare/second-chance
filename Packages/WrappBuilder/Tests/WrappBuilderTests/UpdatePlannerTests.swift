import Foundation
import Testing
import GameCatalog
import WrappFormat
import WrappModules
@testable import WrappBuilder

struct UpdatePlannerTests {
    // MARK: - Fixtures

    private static let installDir = "C:/Program Files (x86)/Nancy Drew/Game"

    private func manifest(updates: [[String: Any]] = [], version: Int = 3) throws -> Manifest {
        try Manifest.decode([
            "format": 1, "id": "nancy-drew/example", "version": version, "title": "Example",
            "editions": [
                ["id": "cd", "source": "disc", "build": ["target": "disc"]],
                ["id": "steam", "source": "steam"],
            ],
            "updates": updates,
        ] as [String: Any])
    }

    private func module(_ id: String, release: Int, version: String, updates: [[String: Any]] = []) throws -> ModuleFolder {
        let manifest = try Manifest.decodeKebab(ModuleManifest.self, from: [
            "format": 1, "id": id, "release": release, "versions": [["version": version]], "updates": updates,
        ] as [String: Any])
        return ModuleFolder(folder: URL(fileURLWithPath: "/modules/\(id)"), manifest: manifest)
    }

    private func shippedLikeModules() throws -> [ModuleFolder] {
        [
            try module("wine", release: 2, version: "10.0_8",
                       updates: [["id": "wine-prefix", "when-changed": ["stages/prefix"]]]),
            try module("steam", release: 1, version: "1", updates: [["id": "steam", "fresh-build": true]]),
            try module("nancy-drew", release: 2, version: "1"),
        ]
    }

    private func target(edition: String = "cd", prefixHash: String = "new",
                        modules extra: [WrappLock.ModuleRef] = []) -> UpdatePlanner.Target {
        UpdatePlanner.Target(
            bundleVersion: 3, edition: edition,
            modules: [
                .init(id: "wine", release: 2, version: "10.0_8", files: ["stages/prefix": prefixHash]),
                .init(id: "nancy-drew", release: 2, version: "1"),
            ] + extra,
            launch: RecordedLaunch(program: "wine:\(Self.installDir)/Game.exe")
        )
    }

    private func lock(bundle: Int = 3, edition: String = "cd", wine: String = "10.0_8", wineRelease: Int = 2,
                      prefixHash: String? = "new", installDir: String = installDir,
                      extra: [WrappLock.ModuleRef] = []) -> WrappLock {
        var lock = WrappLock(
            bundle: .init(id: "nancy-drew/example", version: bundle), edition: edition, source: "disk",
            composition: Composition(launcher: .wine),
            modules: [
                .init(id: "wine", release: wineRelease, version: wine, files: prefixHash.map { ["stages/prefix": $0] }),
                .init(id: "nancy-drew", release: 2, version: "1"),
            ] + extra,
            builtBy: "0.9.0"
        )
        lock.launch = RecordedLaunch(program: "wine:\(installDir)/Game.exe")
        return lock
    }

    /// Stages and the modules each `USE`s, as the planner would work them out.
    private func planner(updates: [[String: Any]] = [], stages: [String: [String]] = [:]) throws -> UpdatePlanner {
        UpdatePlanner(manifest: try manifest(updates: updates), modules: try shippedLikeModules()) { stage in
            stages[stage] ?? ["wine"]
        }
    }

    private func chain(_ decision: UpdatePlanner.Decision) throws -> UpdatePlanner.Chain {
        guard case .update(let chain) = decision else {
            Issue.record("expected an update, got \(decision)")
            throw CancellationError()
        }
        return chain
    }

    // MARK: - Tests

    @Test("A wrapp built by this build has nothing to update: its files are carried into a new wrapp")
    func upToDate() throws {
        let chain = try chain(try planner().plan(old: lock(), target: target()))
        #expect(chain.applied.isEmpty)
        #expect(chain.steps.isEmpty)
        #expect(chain.moves.isEmpty)
        #expect(chain.previous["bundle"] == "3")
        #expect(chain.previous["wine"] == "10.0_8")
    }

    @Test("A changed prefix stage brings Wine's default update, done by its own Swift")
    func winePrefixUpdate() throws {
        let chain = try chain(try planner().plan(old: lock(wineRelease: 1, prefixHash: "old"), target: target()))
        #expect(chain.applied == ["wine-prefix"])
        #expect(chain.steps == [.module("wine", update: "wine-prefix")])
    }

    @Test("A Wine release that only changed launch code needs no update of the prefix")
    func wineReleaseOnly() throws {
        let chain = try chain(try planner().plan(old: lock(wineRelease: 1), target: target()))
        #expect(chain.applied.isEmpty)
    }

    @Test("A newer Wine of the same major version moves the prefix")
    func wineMove() throws {
        let chain = try chain(try planner().plan(old: lock(wine: "10.0_6"), target: target()))
        #expect(chain.moves == [.init(module: "wine", from: "10.0_6", to: "10.0_8")])
    }

    @Test("A wrapp from another major version of Wine is built afresh, unless an update is written for it")
    func wineMajor() throws {
        guard case .freshBuild = try planner().plan(old: lock(wine: "9.0_2"), target: target()) else {
            Issue.record("Wine 9 to 10 should need a fresh build")
            return
        }
        let updates: [[String: Any]] = [["id": "from-wine-9", "from": ["wine": "9"], "build": ["target": "wine-9-to-10"]]]
        let chain = try chain(try planner(updates: updates).plan(old: lock(wine: "9.0_2"), target: target()))
        #expect(chain.applied == ["from-wine-9"])
        #expect(chain.steps == [.stage("wine-9-to-10", updates: ["from-wine-9"])])
        #expect(chain.moves == [.init(module: "wine", from: "9.0_2", to: "10.0_8")])
    }

    @Test("An update applies by the bundle's version")
    func byBundleVersion() throws {
        let updates: [[String: Any]] = [["id": "taffy-patch", "from": ["bundle": "<3"], "build": ["target": "add-taffy-patch"]]]
        let old = try chain(try planner(updates: updates).plan(old: lock(bundle: 2), target: target()))
        #expect(old.applied == ["taffy-patch"])
        let current = try chain(try planner(updates: updates).plan(old: lock(bundle: 3), target: target()))
        #expect(current.applied.isEmpty)
    }

    @Test("Updates run in order, each from where the last left the program")
    func chained() throws {
        let updates: [[String: Any]] = [
            ["id": "one", "from": ["bundle": "<2"], "to": ["bundle": 2], "build": ["target": "first"]],
            ["id": "two", "from": ["bundle": 2], "build": ["target": "second"]],
        ]
        let chain = try chain(try planner(updates: updates).plan(old: lock(bundle: 1), target: target()))
        #expect(chain.applied == ["one", "two"])
        #expect(chain.steps == [.stage("first", updates: ["one"]), .stage("second", updates: ["two"])])
    }

    @Test("Updates that share a stage run it once")
    func sharedStage() throws {
        let updates: [[String: Any]] = [
            ["id": "one", "from": ["bundle": "<3"], "build": ["target": "fixes"]],
            ["id": "two", "from": ["bundle": "<3"], "build": ["target": "fixes"]],
        ]
        let chain = try chain(try planner(updates: updates).plan(old: lock(bundle: 1), target: target()))
        #expect(chain.steps == [.stage("fixes", updates: ["one", "two"])])
    }

    @Test("An update with no build runs the edition's target, and nothing after it applies")
    func editionTarget() throws {
        let updates: [[String: Any]] = [["id": "refresh"], ["id": "later", "build": ["target": "later"]]]
        let chain = try chain(try planner(updates: updates).plan(old: lock(bundle: 1, wineRelease: 1, prefixHash: "old"), target: target()))
        #expect(chain.applied == ["refresh"])
        #expect(chain.steps == [.stage("disc", updates: ["refresh"])])
    }

    @Test("A fresh-build update means the wrapp is built afresh from its source")
    func freshBuildUpdate() throws {
        let updates: [[String: Any]] = [["id": "rebuild", "from": ["bundle": "<2"], "fresh-build": true]]
        guard case .freshBuild(let reason) = try planner(updates: updates).plan(old: lock(bundle: 1), target: target()) else {
            Issue.record("expected a fresh build")
            return
        }
        #expect(reason.contains("rebuild"))
    }

    @Test("A Steam wrapp with another Steam is built afresh from Steam")
    func steam() throws {
        let steam = WrappLock.ModuleRef(id: "steam", release: 0, version: "1")
        let decision = try planner().plan(old: lock(edition: "steam", extra: [steam]),
                                          target: target(edition: "steam", modules: [.init(id: "steam", release: 1, version: "1")]))
        guard case .freshBuild = decision else {
            Issue.record("expected a fresh build, got \(decision)")
            return
        }
    }

    @Test("A bundle can run a module's default update before its own, by naming it")
    func defaultReordered() throws {
        let updates: [[String: Any]] = [["id": "wine-prefix"], ["id": "mine", "from": ["bundle": "<3"], "build": ["target": "mine"]]]
        let chain = try chain(try planner(updates: updates).plan(old: lock(bundle: 1, prefixHash: "old"), target: target()))
        #expect(chain.applied == ["wine-prefix", "mine"])
    }

    @Test("Another edition, program or install folder is a fresh build")
    func mismatches() throws {
        for (old, why) in [
            (lock(edition: "steam"), "edition"),
            (lock(installDir: "C:/Elsewhere"), "install folder"),
        ] {
            guard case .freshBuild = try planner().plan(old: old, target: target()) else {
                Issue.record("another \(why) should be a fresh build")
                continue
            }
        }
        var other = lock()
        other.bundle.id = "nancy-drew/other"
        guard case .freshBuild = try planner().plan(old: other, target: target()) else {
            Issue.record("another program should be a fresh build")
            return
        }
    }

    @Test("A lock with its launch builds afresh only when the program moved")
    func recordedLaunch() throws {
        var old = lock()
        old.launch = RecordedLaunch(program: "wine:\(Self.installDir)/Game.exe")
        if case .freshBuild = try planner().plan(old: old, target: target()) { Issue.record("the same program isn't a move") }
        old.launch = RecordedLaunch(program: "wine:C:/Elsewhere/Game.exe")
        guard case .freshBuild = try planner().plan(old: old, target: target()) else {
            Issue.record("a program that moved should be a fresh build")
            return
        }
    }

    @Test("An old ScummVM app, its data in its prefix, is updated in place, not built afresh")
    func oldScummVMApp() throws {
        var old = lock()
        old.composition = Composition(launcher: .scummvm)
        var scummvm = target()
        scummvm.launch = RecordedLaunch(program: "scummvm:/SharedSupport/game/", arguments: ["nancy:nancy7"])
        if case .freshBuild(let why) = try planner().plan(old: old, target: scummvm) { Issue.record("built afresh: \(why)") }
    }

    @Test("A wrapp from before locks gets one made up from its settings")
    func madeUpLock() throws {
        let settings = WrappSettings(gameExePath: "/Program Files (x86)/Nancy Drew/Game/Game.exe", engine: .wine,
                                     gameSlug: "example", source: nil, installerDir: "/nancy-drew-installer/disk-1")
        let made = WrappLock.madeUp(settings: settings, program: "nancy-drew/example", edition: "cd", wineVersion: "10.0_8")
        #expect(made.bundle.version == 0)
        #expect(made.launch?.program == "wine:\(Self.installDir)/Game.exe")
        #expect(made.source == "disk")
        #expect(made.modules.map(\.id) == ["wine"])
        // Its prefix was set up by a prefix stage nothing recorded: Wine's
        // default update applies it again.
        let chain = try chain(try planner().plan(old: made, target: target()))
        #expect(chain.applied == ["wine-prefix"])
    }

    @Test("The Wine engine's version file reads as the wine module writes versions",
          arguments: [("wine sikarugir 10.0 (revision 8)\n", "10.0_8"), ("wine-9.0", nil), ("wine 9.0", "9.0")])
    func wineVersionFile(text: String, expected: String?) {
        #expect(WrappLock.wineVersion(fromVersionFile: text) == expected)
    }

    @Test("The shipped Wine and Steam modules declare their default updates")
    func shippedDefaults() throws {
        let modules = Dictionary(uniqueKeysWithValues: try shippedModules().map { ($0.manifest.id, $0.manifest) })
        #expect(modules["wine"]?.updates?.map(\.id) == ["wine-prefix"])
        #expect(modules["wine"]?.updates?.first?.whenChanged == ["stages/prefix"])
        #expect(modules["steam"]?.updates?.first?.freshBuild == true)
    }
}
