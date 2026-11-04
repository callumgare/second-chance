import Foundation
import Testing
@testable import WrappBuilder
import WrappFormat

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
        // The wine module's prefix stage, which the bundle's is built from.
        #expect(plan.stages.map(\.name) == ["wine/prefix", "prefix", "disc"])
        #expect(plan.stages[1].modules == ["nancy-drew", "wine"])
        // cnc-ddraw, as Blue Moon draws with DirectDraw, and the icon.
        #expect(plan.stages[1].steps.map { "\($0.module ?? "").\($0.instruction)" } == ["wine.WINETRICKS", ".EDIT", ".COPY", ".APP"])
        #expect(plan.stages[2].modules == ["installer", "nancy-drew", "wine"])
        let steps = plan.stages[2].steps
        let installDir = "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"
        #expect(steps.map { "\($0.module ?? "").\($0.instruction)" } == [
            "wine.KEEP-DISCS", "installer.RUN", ".RUN", "nancy-drew.CONFIGURE-INI",
        ])
        let install = steps[1]
        #expect(install.option("into") == "wine:" + installDir)
        #expect(install.option("from") == "input:disc-1")
        #expect(install.option("answer-file") == "bundle:assets/disc.iss")
        #expect(plan.file("bundle:assets/disc.iss")?.path.hasSuffix("Bundles/nancy-drew/blue-moon/assets/disc.iss") == true)
        #expect(plan.file("module:nancy-drew:/assets/her-update-wizard.au3") != nil)
        // blue-moon-taffy-sort is a wizard: run under AutoIt, from the module's assets.
        let patch = steps[2]
        #expect(patch.name == "blue-moon-taffy-sort")
        #expect(patch.arguments == ["wine:C:/autoit/AutoIt3.exe", "/ErrorStdOut", "C:/patch.au3", "\(installDir)/TRN_Patch.exe"])
        #expect(patch.description.hasPrefix("RUN --mount=type=fetch,url=https://"))
        let mounts = try #require(patch.options["mount"])
        #expect(mounts.first?.hasPrefix("type=fetch,url=https://") == true)
        #expect(mounts.contains { $0.contains("source=module:nancy-drew:/assets/her-update-wizard.au3") })
        #expect(mounts.contains { $0.contains("source=module:installer:/autoit") })
        #expect(patch.origin.hasPrefix("nancy-drew/functions/patch:"))
        // The game's .ini settings, which the stage writes after its patches.
        #expect(steps[3].arguments == ["wine:\(installDir)"])
        #expect(steps[0].description
                == "WINE.KEEP-DISCS --combined=wine:C:/nancy-drew-installer/disk-combined --into=wine:C:/nancy-drew-installer input:disc-1 input:disc-2")
    }

    @Test("Each kind of patch takes its own branch")
    func patchBranches() throws {
        let lostQueen = try #require(try plan("lost-queen", edition: "cd")).target?.steps ?? []
        let copy = try #require(lostQueen.first { $0.name == "lost-queen-decode-puzzle" })
        #expect(copy.instruction == "ADD" && copy.option("unpack") == "zip" && copy.option("checksum")?.hasPrefix("sha256:") == true)
        // Scarlet Hand's is the one self-extracting zip; no edition applies it now, as ScummVM does.
        let extract = try #require(try steps("""
        FROM scratch AS only
        USE nancy-drew
        DO nancy-drew.patch --id=scarlet-hand-phone-monolith --into=C:/game
        """).first)
        #expect(extract.instruction == "ADD" && extract.has("extract"))
        #expect(extract.arguments.last == "wine:C:/game/DataFiles")

        // A ScummVM disc edition that needs no Wine: its discs copied into the app.
        let scarlet = try #require(try plan("scarlet-hand", edition: "cd"))
        #expect(scarlet.stages.map(\.name) == ["scummvm", "disc"])
        #expect(scarlet.target?.modules == ["scummvm"])
        #expect(scarlet.target?.steps.map(\.description) == ["COPY --from=input:disc-1 . /SharedSupport/game/"])
        #expect(scarlet.launch == RecordedLaunch(program: "scummvm:/SharedSupport/game/", arguments: ["nancy:nancy6"], mounts: [
            .init(store: "app:scummvm-saves", target: "scummvm:saves/"), .init(store: "app:scummvm-settings", target: "scummvm:settings/"),
        ], format: RecordedLaunch.currentFormat))
        #expect(scarlet.icon == "/Resources/nancy-drew.icns")
    }

    @Test("A Steam edition is built from the steam module's client stage, and the choice decides its launch")
    func steamPlans() throws {
        func plan(_ mode: String) throws -> BuildPlan {
            try #require(try self.plan("old-clock", edition: "steam", conditions: BuildConditions(arch: "arm64", macos: 15, choices: ["launch-mode": mode])))
        }
        let steam = try plan("steam")
        // The client stage is built from the wine module's prefix, each planned once.
        #expect(steam.stages.map(\.name) == ["wine/prefix", "steam/client", "steam"])
        #expect(steam.stages[1].steps.map { "\($0.module ?? "").\($0.instruction)" }
                == ["steam.CLIENT", "wine.REGISTRY", "wine.REGISTRY", "wine.REGISTRY", "wine.REGISTRY"])
        #expect(steam.bundleSteps.map { "\($0.module ?? "").\($0.instruction)" }
                == ["wine.WINETRICKS", ".EDIT", ".COPY", "steam.INSTALL", "steam.SIGN-OUT", "nancy-drew.CONFIGURE-INI"])
        let exe = "wine:C:/Nancy Drew/Secret of the Old Clock/Game.exe"
        #expect(steam.launch?.program == "steam://rungameid/31880")
        #expect(steam.launch?.options == ["wine.graphics": "direct-draw", "wine.cursor-lock": "", "steam.exe": exe])
        #expect(steam.launch?.fallback == exe)
        let direct = try plan("direct")
        #expect(direct.bundleSteps.last?.instruction == "REMOVE")
        #expect(direct.launch?.program == exe)
        #expect(direct.launch?.fallback == nil)
    }

    @Test("A function's USE is the calling stage's, as if written there")
    func functionUses() throws {
        let (planner, _, bundle) = try planner("""
        FUNCTION shared
          USE nancy-drew
        END
        FROM --module=wine@10 prefix AS only
        DO shared
        DO nancy-drew.configure-ini --into=C:/Game
        LAUNCH --wine.graphics=direct-3d C:/Game/Game.exe
        """)
        let plan = try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        #expect(plan.target?.modules.contains("nancy-drew") == true)
        #expect(plan.target?.steps.last?.keyword == "NANCY-DREW.CONFIGURE-INI")
    }

    @Test("A function of the bundle's sees the file's CONSTs, where it's defined")
    func functionSeesGlobals() throws {
        let (planner, _, bundle) = try planner("""
        CONST install-dir = "C:/Game"
        FUNCTION installed
          USE nancy-drew
          DO nancy-drew.configure-ini --into=${const.install-dir}
        END
        FROM --module=wine@10 prefix AS only
        DO installed
        LAUNCH --wine.graphics=direct-3d ${const.install-dir}/Game.exe
        """)
        let plan = try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        #expect(plan.target?.steps.last?.arguments == ["wine:C:/Game"])
    }

    @Test("A CONST can be built from another")
    func constFromConst() throws {
        let (planner, _, bundle) = try planner("""
        CONST folder = "C:/Game"
        CONST program = "${const.folder}/Game.exe"
        FROM --module=wine@10 prefix AS only
        LAUNCH --wine.graphics=direct-3d ${const.program}
        """)
        let plan = try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        #expect(plan.launch?.program == "wine:C:/Game/Game.exe")
    }

    @Test("An install's --creates is the launch's program when the launch is in its folder")
    func createsIsTheLaunch() throws {
        func plan(creates: String) throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            FROM --module=wine@10 prefix AS only
            USE installer
            INSTALLER.RUN --from=/disc --into=C:/Game --creates=\(creates)
            LAUNCH --wine.graphics=direct-3d C:/Game/Game.exe
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        #expect(try plan(creates: "C:/Game/Game.exe").launch?.program == "wine:C:/Game/Game.exe")
        #expect(throws: BuildPlanner.PlanError.self) { try plan(creates: "C:/Game/Other.exe") }
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
        // A module's setup, which USE plans, has tests of its own (StageTreesTests).
        return try context.plan(stage, globals: try context.globalScope(), inheriting: [:]).stage.steps.filter { !$0.setup }
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

    @Test("A function's INPUT is a DO's option, else its default, never a caller's value of the same name")
    func functionInputs() throws {
        func text(_ calls: String) -> String {
            """
            CONST into = "C:/caller"
            FUNCTION drop
              INPUT into
              INPUT name --default="default"
              REMOVE "${input.into}/${input.name}"
            END
            FROM scratch AS only
            USE wine
            \(calls)
            """
        }
        #expect(try steps(text("DO drop --into=C:/given")).flatMap(\.arguments) == ["wine:C:/given/default"])
        #expect(try steps(text("DO drop --into=C:/given --name=x")).flatMap(\.arguments) == ["wine:C:/given/x"])
        // The CONST called into is the file's, not the INPUT's value.
        #expect(throws: BuildPlanner.PlanError.self) { try steps(text("DO drop")) }
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
        RUN --mount=type=bind,id=disc,w.drive=D:,target=wine:C:/d wine:C:/a.exe /c C:/not-a-path
        COPY --from=x . dosbox:C:/GAME/
        REMOVE /SharedSupport/x
        FROM scratch AS lonely
        USE scummvm
        DO drop --into=C:/y
        """
        #expect(try steps(text).map(\.description) == [
            "RUN --mount=type=bind,id=disc,wine.drive=D:,target=wine:C:/d wine:C:/a.exe /c C:/not-a-path",
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

    @Test("EMIT is kept with its stage before the step after it: through a function, dropped with an untaken branch, never a step")
    func emits() throws {
        let text = """
        FUNCTION patch
          EMIT "patching"
          REMOVE /a
        END
        FROM scratch AS only
        EMIT "first"
        REMOVE /b
        IF ${platform.arch} = "nothing"
          EMIT "never"
        END
        DO patch
        EMIT "last ${platform.arch}"
        """
        let (planner, file, bundle) = try planner(text)
        let context = BuildPlanner.Context(planner: planner, edition: bundle.manifest.editions[0],
                                           conditions: BuildConditions(arch: "arm64", macos: 15), recorder: BuildPlanner.Recorder())
        let stage = try context.plan(try #require(file.stage(named: "only")), globals: try context.globalScope(), inheriting: [:]).stage
        #expect(stage.steps.map(\.description) == ["REMOVE /b", "REMOVE /a"])
        #expect(stage.emits.map { "\($0.before) \($0.text)" } == ["0 first", "1 patching", "2 last arm64"])
    }
}
