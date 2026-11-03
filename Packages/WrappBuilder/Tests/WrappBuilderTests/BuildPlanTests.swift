import Foundation
import Testing
@testable import WrappBuilder

struct BuildPlanTests {
    private func plan(_ slug: String, edition: String,
                      conditions: BuildConditions = BuildConditions(arch: "arm64", macos: 15)) throws -> BuildPlan? {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/\(slug)")).get()
        let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        return try BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules).plan(edition: edition, conditions: conditions)
    }

    @Test("A disc edition: its stages in order, functions expanded, substitutions made, assemble last")
    func blueMoonsDisc() throws {
        let plan = try #require(try plan("blue-moon", edition: "cd"))
        #expect(plan.stages.map(\.name) == ["prefix", "disc"])
        #expect(plan.stages[0].modules == ["wine"])
        #expect(plan.stages[1].modules == ["installer", "nancy-drew", "wine"])
        let steps = plan.stages[1].steps
        let installDir = "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"
        #expect(steps.map { "\($0.module ?? "").\($0.instruction)" } == [
            "wine.KEEP-DISCS", "installer.RUN", ".RUN", ".EDIT",
        ])
        let install = steps[1]
        #expect(install.option("into") == "wine:" + installDir)
        #expect(install.option("from") == "disc-1")
        #expect(install.option("answer-file")?.hasSuffix("Bundles/nancy-drew/blue-moon/assets/disc.iss") == true)
        #expect(install.option("answer-file")?.hasPrefix("asset:/") == true)
        // blue-moon-taffy-sort is a wizard: run under AutoIt, from the module's assets.
        let patch = steps[2]
        #expect(patch.name == "blue-moon-taffy-sort")
        #expect(patch.arguments == ["wine:C:/autoit/AutoIt3.exe", "C:/patch.au3", "\(installDir)/TRN_Patch.exe"])
        #expect(patch.description.hasPrefix("RUN --mount=type=fetch,url=https://"))
        let mounts = try #require(patch.options["mount"])
        #expect(mounts.first?.hasPrefix("type=fetch,url=https://") == true)
        #expect(mounts.contains { $0.contains("source=assets/her-update-wizard.au3") })
        #expect(patch.origin.hasPrefix("nancy-drew/functions/patch:"))
        // The module's assemble step, with the bundle's install-dir.
        #expect(steps[3].arguments == ["wine:\(installDir)/*.ini"])
        #expect(plan.stages[1].steps[0].description == "WINE.KEEP-DISCS --combined=wine:C:/nancy-drew-installer/disk-combined --into=wine:C:/nancy-drew-installer")
        #expect(steps[3].option("from-data") == "ini")
    }

    @Test("Each kind of patch takes its own branch")
    func patchBranches() throws {
        let lostQueen = try #require(try plan("lost-queen", edition: "cd")).target?.steps ?? []
        let copy = try #require(lostQueen.first { $0.name == "lost-queen-decode-puzzle" })
        #expect(copy.instruction == "ADD" && copy.option("unpack") == "zip" && copy.option("checksum")?.hasPrefix("sha256:") == true)
        let scarlet = try #require(try plan("scarlet-hand", edition: "cd")).target?.steps ?? []
        let extract = try #require(scarlet.first { $0.name == "scarlet-hand-phone-monolith" })
        #expect(extract.instruction == "ADD" && extract.has("extract"))
        #expect(try #require(try plan("scarlet-hand", edition: "cd")).target?.modules.contains("scummvm") == true)
    }

    @Test("A Steam edition names no stage: a module's default stages build it")
    func steamHasNoPlan() throws {
        #expect(try plan("old-clock", edition: "steam") == nil)
    }

    @Test func conditionsAreDecidedForTheBuild() throws {
        let file = try WrappfileParser.parse("""
        FROM scratch AS only
        USE wine
        IF arch=arm64
          WINE.WINETRICKS arm
        ELSE IF macos>=26
          WINE.WINETRICKS new
        ELSE
          WINE.WINETRICKS old
        END
        IF updates has fix
          WINE.WINETRICKS fix
        END
        """)
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/old-clock")).get()
        let planner = BuildPlanner(bundle: bundle, wrappfile: file, modules: modules)
        // Old Clock's disc edition builds "disc", which this file hasn't got: plan a stage directly.
        func verbs(_ conditions: BuildConditions) throws -> [String] {
            let stage = try #require(file.stage(named: "only"))
            return try BuildPlanner.Context(planner: planner, edition: bundle.manifest.editions[0], conditions: conditions)
                .plan(stage, inheriting: [:], isTarget: false).stage.steps.flatMap(\.arguments)
        }
        #expect(try verbs(BuildConditions(arch: "arm64", macos: 15)) == ["arm"])
        #expect(try verbs(BuildConditions(arch: "x86_64", macos: 26)) == ["new"])
        #expect(try verbs(BuildConditions(arch: "x86_64", macos: 15, updates: ["fix"])) == ["old", "fix"])
    }

    @Test("Short forms come out in full, aliases as ids, and a function's paths are checked in the stage that calls it")
    func fullForms() throws {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/old-clock")).get()
        let file = try WrappfileParser.parse("""
        FUNCTION drop
          ARG into
          REMOVE ${into}/x
        END
        FROM scratch AS only
        USE wine AS w
        USE dosbox
        RUN --mount=type=source,from=disc-1,w.drive=D:,target=wine:C:/d wine:C:/a.exe /c C:/not-a-path
        COPY --from=disc-1 . dosbox:C:/GAME/
        REMOVE /SharedSupport/x
        FROM scratch AS lonely
        USE scummvm
        DO drop --into=C:/y
        """)
        let planner = BuildPlanner(bundle: bundle, wrappfile: file, modules: modules)
        let context = BuildPlanner.Context(planner: planner, edition: bundle.manifest.editions[0], conditions: .thisMac)
        let steps = try context.plan(try #require(file.stage(named: "only")), inheriting: [:], isTarget: false).stage.steps
        #expect(steps.map(\.description) == [
            "RUN --mount=type=source,from=disc-1,wine.drive=D:,target=wine:C:/d wine:C:/a.exe /c C:/not-a-path",
            "COPY --from=disc-1 . dosbox:C:/GAME/",
            "REMOVE /SharedSupport/x",
        ])
        #expect(throws: BuildPlanner.PlanError.self) {
            try context.plan(try #require(file.stage(named: "lonely")), inheriting: [:], isTarget: false)
        }
    }

    @Test("Every edition of every bundle plans")
    func everyEditionPlans() throws {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        for bundle in try loader.loadAll().get() {
            let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
            let planner = BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
            for edition in bundle.manifest.editions {
                #expect(throws: Never.self, "\(bundle.manifest.id) \(edition.id)") {
                    _ = try planner.plan(edition: edition.id, conditions: .thisMac)
                }
            }
        }
    }
}
