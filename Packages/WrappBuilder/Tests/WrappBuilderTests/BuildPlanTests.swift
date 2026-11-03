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

    @Test("A disc edition: its stages in order, functions expanded, substitutions made")
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
        #expect(install.option("from") == "input:disc-1")
        #expect(install.option("answer-file") == "bundle:assets/disc.iss")
        #expect(plan.file("bundle:assets/disc.iss")?.path.hasSuffix("Bundles/nancy-drew/blue-moon/assets/disc.iss") == true)
        #expect(plan.file("module:nancy-drew/assets/her-update-wizard.au3") != nil)
        // blue-moon-taffy-sort is a wizard: run under AutoIt, from the module's assets.
        let patch = steps[2]
        #expect(patch.name == "blue-moon-taffy-sort")
        #expect(patch.arguments == ["wine:C:/autoit/AutoIt3.exe", "C:/patch.au3", "\(installDir)/TRN_Patch.exe"])
        #expect(patch.description.hasPrefix("RUN --mount=type=fetch,url=https://"))
        let mounts = try #require(patch.options["mount"])
        #expect(mounts.first?.hasPrefix("type=fetch,url=https://") == true)
        #expect(mounts.contains { $0.contains("source=module:nancy-drew/assets/her-update-wizard.au3") })
        #expect(mounts.contains { $0.contains("source=module:installer/autoit") })
        #expect(patch.origin.hasPrefix("nancy-drew/functions/patch:"))
        // The game's .ini settings, which the stage writes after its patches.
        #expect(steps[3].arguments == ["wine:\(installDir)/*.ini"])
        #expect(plan.stages[1].steps[0].description
                == "WINE.KEEP-DISCS --combined=wine:C:/nancy-drew-installer/disk-combined --into=wine:C:/nancy-drew-installer input:disc-1 input:disc-2")
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

    /// A planner over Old Clock's bundle and the shipped modules, for a
    /// Wrappfile of a test's own.
    private func planner(_ text: String, slug: String = "old-clock") throws -> (BuildPlanner, Wrappfile, ProgramBundle) {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/\(slug)")).get()
        let file = try WrappfileParser.parse(text)
        return (BuildPlanner(bundle: bundle, wrappfile: file, modules: modules), file, bundle)
    }

    /// The steps `stage` plans to, for Old Clock's disc edition.
    private func steps(_ text: String, stage: String = "only", conditions: BuildConditions = BuildConditions(arch: "arm64", macos: 15),
                       edition: Int = 0) throws -> [PlannedStep] {
        let (planner, file, bundle) = try planner(text)
        let context = BuildPlanner.Context(planner: planner, edition: bundle.manifest.editions[edition], conditions: conditions,
                                           recorder: BuildPlanner.Recorder())
        let stage = try #require(file.stage(named: stage))
        return try context.plan(stage, globals: try context.globalScope(), inheriting: [:]).stage.steps
    }

    @Test func conditionsAreDecidedForTheBuild() throws {
        let text = """
        FROM scratch AS only
        USE wine
        IF ${platform.arch} = "arm64"
          WINE.WINETRICKS arm
        ELSE IF ${platform.macos} != "15"
          WINE.WINETRICKS new
        ELSE
          WINE.WINETRICKS old
        END
        """
        #expect(try steps(text, conditions: BuildConditions(arch: "arm64", macos: 15)).flatMap(\.arguments) == ["arm"])
        #expect(try steps(text, conditions: BuildConditions(arch: "x86_64", macos: 26)).flatMap(\.arguments) == ["new"])
        #expect(try steps(text, conditions: BuildConditions(arch: "x86_64", macos: 15)).flatMap(\.arguments) == ["old"])
    }

    @Test("CONST, VAR and SET: the innermost wins, a branch's SET changes the outer VAR, a branch's VAR shadows it")
    func scopes() throws {
        let text = """
        CONST dir = "C:/a"
        VAR exe = "Game.exe"
        FROM scratch AS only
        USE wine
        IF ${platform.arch} = "arm64"
          SET exe = "Game64.exe"
          VAR shadow = "inner"
        END
        VAR shadow = "outer"
        IF ${platform.arch} = "arm64"
          VAR shadow = "branch's own"
        END
        REMOVE "${const.dir}/${var.exe}"
        REMOVE "${const.dir}/${var.shadow}"
        """
        #expect(try steps(text).flatMap(\.arguments) == ["wine:C:/a/Game64.exe", "wine:C:/a/outer"])
        #expect(try steps(text, conditions: BuildConditions(arch: "x86_64", macos: 15)).flatMap(\.arguments)
                == ["wine:C:/a/Game.exe", "wine:C:/a/outer"])
    }

    @Test("A VAR read before anything sets it, and a SET of no VAR, are refused")
    func unsetValues() throws {
        #expect(throws: BuildPlanner.PlanError.self) { try steps("VAR x\nFROM scratch AS only\nUSE wine\nREMOVE ${var.x}") }
        #expect(throws: BuildPlanner.PlanError.self) { try steps("FROM scratch AS only\nUSE wine\nSET x = \"1\"") }
    }

    @Test("An input reads the edition's value, else its default; one with neither is an error only when read")
    func inputs() throws {
        // Old Clock's steam edition has the launch-mode choice: edition 2.
        let (_, _, bundle) = try planner("FROM scratch")
        let steam = try #require(bundle.manifest.editions.firstIndex { $0.id == "steam" })
        let text = """
        INPUT launch-mode --default="other"
        INPUT missing
        INPUT given --default="fallback"
        FROM scratch AS only
        USE wine
        REMOVE "C:/${input.launch-mode}/${input.given}"
        """
        #expect(try steps(text, edition: steam).flatMap(\.arguments) == ["wine:C:/direct/fallback"])
        #expect(try steps(text, conditions: BuildConditions(arch: "arm64", macos: 15, choices: ["launch-mode": "steam"]),
                          edition: steam).flatMap(\.arguments) == ["wine:C:/steam/fallback"])
        #expect(throws: BuildPlanner.PlanError.self) { try steps(text + "\nREMOVE ${input.missing}", edition: steam) }
    }

    @Test("A whole input where one is taken is its token; its fields are text")
    func inputTokens() throws {
        let text = """
        INPUT disc-1
        FROM scratch AS only
        USE installer
        INSTALLER.RUN --from=${input.disc-1} --into="C:/${input.disc-1.type}"
        """
        let run = try #require(try steps(text).first)
        #expect(run.option("from") == "input:disc-1")
        #expect(run.option("into") == "wine:C:/disc")
    }

    @Test("A function reads its caller's values only through its INPUTs: a DO's option, else the caller's of that name, else its default")
    func functionInputs() throws {
        let text = """
        CONST into = "C:/caller"
        FUNCTION drop
          INPUT into
          INPUT name --default="default"
          REMOVE "${input.into}/${input.name}"
        END
        FROM scratch AS only
        USE wine
        DO drop
        DO drop --into=C:/given --name=x
        """
        #expect(try steps(text).flatMap(\.arguments) == ["wine:C:/caller/default", "wine:C:/given/x"])
    }

    @Test("A module's data reads its schema's defaults, and self is the module whatever its AS name")
    func moduleData() throws {
        // Neither field is in this patch's entry: automation's default, none,
        // takes the silent patcher's branch, and destinationSubdirectory's, "",
        // would put it in the folder itself.
        let planned = try steps("""
        FROM scratch AS only
        USE installer
        USE nancy-drew AS nd
        DO nd.patch --id=secrets-can-kill-flower-puzzle --into=C:/game
        """)
        let run = try #require(planned.first)
        #expect(run.module == "installer" && run.instruction == "RUN")
        #expect(run.option("into") == "wine:C:/game")
        #expect(try steps("FROM scratch AS only\nUSE wine\nREMOVE C:/${module.wine.version}").flatMap(\.arguments) == ["wine:C:/10.0_8"])
        #expect(try steps("FROM scratch AS only\nUSE wine\nREMOVE C:/${wine.version}").flatMap(\.arguments) == ["wine:C:/10.0_8"])
    }

    @Test("A secret input never reaches a step's text")
    func secrets() throws {
        let text = """
        INPUT password --secret --default="hunter2"
        FROM scratch AS only
        USE wine
        RUN --env PASSWORD=${input.password} C:/sign-in.exe
        """
        let run = try #require(try steps(text).first)
        #expect(run.description == "RUN --env=PASSWORD=${input.password} wine:C:/sign-in.exe")
    }

    @Test("Short forms come out in full, aliases as ids, and a function's paths are checked in the stage that calls it")
    func fullForms() throws {
        let text = """
        FUNCTION drop
          INPUT into
          REMOVE ${input.into}/x
        END
        FROM scratch AS only
        USE wine AS w
        USE dosbox
        RUN --mount=type=source,from=disc-1,w.drive=D:,target=wine:C:/d wine:C:/a.exe /c C:/not-a-path
        COPY --from=x . dosbox:C:/GAME/
        REMOVE /SharedSupport/x
        FROM scratch AS lonely
        USE scummvm
        DO drop --into=C:/y
        """
        #expect(try steps(text).map(\.description) == [
            "RUN --mount=type=source,from=disc-1,wine.drive=D:,target=wine:C:/d wine:C:/a.exe /c C:/not-a-path",
            "COPY --from=x . dosbox:C:/GAME/",
            "REMOVE /SharedSupport/x",
        ])
        #expect(throws: BuildPlanner.PlanError.self) { try steps(text, stage: "lonely") }
    }

    @Test("An edition's input its target never reads is an error")
    func unusedInputs() throws {
        let (planner, _, _) = try planner("FROM scratch AS disc\nUSE wine")
        #expect(throws: BuildPlanner.PlanError.self) {
            _ = try planner.plan(edition: "cd", conditions: BuildConditions(arch: "arm64", macos: 15))
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
