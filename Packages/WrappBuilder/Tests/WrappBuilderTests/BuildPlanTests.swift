import Foundation
import Testing
@testable import WrappBuilder
import WrappModules
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
        ], format: RecordedLaunch.currentFormat, module: .scummvm))
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
        #expect(steam.launch?.options == ["wine.graphics": "direct-draw", "wine.mouse": "grab-early", "steam.exe": exe])
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

    @Test("A cnc-ddraw launch says what cnc-ddraw does with the mouse, or is warned about; free sets devmode for its exe")
    func cursorLockOrFree() throws {
        func plan(_ options: String) throws -> BuildPlan? {
            let (planner, _, bundle) = try planner("""
            INPUT disc-1
            FROM --module=wine@10 prefix AS disc
            DO wine.cnc-ddraw
            COPY --from=${input.disc-1} . C:/Game/
            LAUNCH --wine.graphics=direct-draw \(options) C:/Game/Game.exe
            """)
            // The edition's plan: where planning checks the launch against
            // its stages.
            return try planner.plan(edition: bundle.manifest.editions[0].id, conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        let early = try plan("--wine.mouse=grab-early")
        #expect(early?.launch?.options["wine.mouse"] == "grab-early")
        #expect(early?.target?.steps.contains { $0.options["ini"]?.contains("game.devmode=true") == true } == false)
        // Free: cnc-ddraw's devmode, for the launch's exe only.
        let free = try #require(try plan("--wine.mouse=free"))
        let last = try #require(free.target?.steps.last)
        #expect(last.description == "EDIT --ini=game.devmode=true wine:C:/windows/syswow64/ddraw.ini")
        // Saying neither builds, and is a warning for sc bundle check and sc lint.
        let neither = try #require(try plan(""))
        #expect(BuildPlanner.warnings(of: neither).first?.contains("--wine.mouse") == true)
        #expect(BuildPlanner.warnings(of: free).isEmpty)
        #expect(throws: BuildPlanner.PlanError.self) { try plan("--wine.mouse=locked") }
    }

    @Test("--wine.display-mode is recorded as a width and height, and anything else is refused when planning")
    func displayMode() throws {
        func plan(_ options: String) throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            FROM --module=wine@10 prefix AS only
            LAUNCH --wine.graphics=unknown \(options) C:/Game/Game.exe
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        #expect(try plan("--wine.display-mode=800x600").launch?.displayMode == RecordedLaunch.DisplayMode(width: 800, height: 600))
        #expect(try plan("").launch?.displayMode == nil)
        for bad in ["800", "800x", "x600", "800*600", "100x100", "800x600x32", "wide"] {
            #expect(throws: BuildPlanner.PlanError.self) { try plan("--wine.display-mode=\(bad)") }
        }
    }

    @Test("--wine.quit-confirm-key is recorded beside a quit key, and refused without one")
    func quitConfirmKey() throws {
        func plan(_ options: String) throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            FROM --module=wine@10 prefix AS only
            LAUNCH --wine.graphics=direct-draw \(options) C:/Game/Game.exe
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        let both = try plan("--wine.quit-key=escape --wine.quit-confirm-key=\"escape escape\"")
        #expect(both.launch?.quitKey == "escape")
        #expect(both.launch?.quitConfirmKey == "escape escape")
        #expect(throws: BuildPlanner.PlanError.self) { try plan("--wine.quit-confirm-key=escape") }
    }

    @Test("Quit keys are recorded as written, and keys the notation refuses are refused when planning, naming the bad part")
    func quitKeyNotation() throws {
        func plan(_ options: String) throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            FROM --module=wine@10 prefix AS only
            LAUNCH --wine.graphics=direct-draw \(options) C:/Game/Game.exe
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        let icy = try plan("--wine.quit-key=escape --wine.quit-confirm-key=escape:hold=5s")
        #expect(icy.launch?.quitConfirmKey == "escape:hold=5s")
        #expect(try plan("--wine.quit-key=\"up return*2\"").launch?.quitKey == "up return*2")
        #expect {
            try plan("--wine.quit-key=f12:hold=40s")
        } throws: { error in
            "\(error)".contains("--wine.quit-key=f12:hold=40s") && "\(error)".contains("at most 30s")
        }
        #expect(throws: BuildPlanner.PlanError.self) { try plan("--wine.quit-key=escape --wine.quit-confirm-key=enter*0") }
        #expect(try plan("--wine.quit-key=\"gap=300ms up wait=0 return\"").launch?.quitKey == "gap=300ms up wait=0 return")
        #expect {
            try plan("--wine.quit-key=\"escape wait=1s\"")
        } throws: { error in
            "\(error)".contains("wait=1s: a wait goes between two steps, not after the last")
        }
    }

    @Test("--wine.fullscreen-setting is recorded with ${…} filled in, and a bad one refused saying why")
    func fullscreenSetting() throws {
        func plan(_ setting: String) throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            CONST dir = "C:/Game"
            FROM --module=wine@10 prefix AS only
            LAUNCH --wine.graphics=direct-draw --wine.fullscreen-setting="\(setting)" ${const.dir}/Game.exe
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        let planned = try plan("file=${const.dir}/game.cfg,format=allegro-packfile,offset=16,bytes=4,fullscreen=-1,windowed=0")
        let setting = try #require(planned.launch?.fullscreenSetting)
        #expect(setting.file == "C:/Game/game.cfg")
        #expect(setting.offset == 16)
        #expect {
            try plan("file=${const.dir}/game.cfg,format=allegro-packfile,offset=16,bytes=3,fullscreen=-1,windowed=0")
        } throws: { error in
            "\(error)".contains("--wine.fullscreen-setting") && "\(error)".contains("bytes=3")
        }
    }

    @Test("The wine update: an old app's tree, given this Wine and the prefix's settings, its drives left alone")
    func wineUpdate() throws {
        let modules = try shippedModules()
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: modules)
        let bundle = try loader.load(bundlesRoot.appendingPathComponent("nancy-drew/blue-moon")).get()
        let wrappfile = try WrappfileParser.parse(String(contentsOf: bundle.folder.appendingPathComponent("Wrappfile"), encoding: .utf8))
        var conditions = BuildConditions(arch: "arm64", macos: 15)
        conditions.updates = ["wine-prefix"]
        conditions.previous = ["bundle": "1", "wine": "10"]
        let planner = BuildPlanner(bundle: bundle, wrappfile: wrappfile, modules: modules)
        #expect(planner.engineModules(["wine", "nancy-drew"]) == ["wine"])
        let plan = try planner.updatePlan(moduleStage: ("wine", "update"), engines: ["wine"], then: ["DO wine.cnc-ddraw"],
                                          edition: "cd", conditions: conditions)
        #expect(plan.stages.map(\.name) == ["wine/update", "update"])
        #expect(plan.stages[0].from == .input("previous"))
        let steps = plan.stages.flatMap(\.steps).map { "\($0.module ?? "").\($0.instruction)" }
        // No PREFIX: the old prefix is made, and wineboot -u over it can
        // wait on Wine's Mono installer (the module's update-setup).
        #expect(steps == [".ENGINE", "wine.HELPERS", "wine.REGISTRY", "wine.WINETRICKS", "wine.WINETRICKS", ".EDIT"])
        #expect(plan.launch == nil)
        // A build without an old app has no tree to start the stage from.
        #expect(throws: BuildPlanner.PlanError.self) {
            try planner.updatePlan(moduleStage: ("wine", "update"), engines: ["wine"], edition: "cd",
                                   conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        // With no module's update: the old app's tree, given this engine.
        let engines = try planner.updatePlan(moduleStage: nil, engines: ["wine"], edition: "cd", conditions: conditions)
        #expect(engines.stages.map(\.from) == [.input("previous")])
        #expect(engines.stages.flatMap(\.steps).map(\.instruction) == ["ENGINE", "HELPERS"])
    }

    @Test("has is true of a list holding the text; INPUT updates is the updates applied, [] by default")
    func hasUpdate() throws {
        func steps(_ updates: [String]) throws -> [String] {
            let (planner, _, bundle) = try planner("""
            INPUT updates --default=[]
            FROM --module=wine@10 prefix AS only
            IF ${input.updates} has "taffy-sort"
              RUN C:/patch.exe
            END
            LAUNCH --wine.graphics=direct-3d C:/Game/Game.exe
            """)
            var conditions = BuildConditions(arch: "arm64", macos: 15)
            conditions.updates = updates
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only", conditions: conditions)
                .target?.steps.map(\.instruction) ?? []
        }
        #expect(try steps(["taffy-sort"]).contains("RUN"))
        #expect(try !steps([]).contains("RUN"))
        #expect(try !steps(["other"]).contains("RUN"))
    }

    @Test("A files= mount records its patterns, from a kept store of the app's own, on a folder")
    func filesMount() throws {
        func plan(_ store: String, target: String = "C:/Game/") throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            \(store)
            FROM --module=wine@10 prefix AS only
            LAUNCH --wine.graphics=direct-3d --mount=type=store,source=saves,target=\(target),files="Game.ini;*.hs" C:/Game/Game.exe
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        let mount = try #require(try plan("STORE saves").launch?.mounts.first)
        #expect(mount.store == "app:saves" && mount.target == "wine:C:/Game/")
        #expect(mount.filePatterns == ["Game.ini", "*.hs"])
        #expect(throws: BuildPlanner.PlanError.self) { try plan("STORE saves --retention=cache") }
        #expect(throws: BuildPlanner.PlanError.self) { try plan("STORE saves --scope=global") }
        #expect(throws: BuildPlanner.PlanError.self) { try plan("STORE saves", target: "C:/Game") }
    }

    @Test("A bare LAUNCH /… is the core's: a file in the app, started by no module")
    func coreLaunch() throws {
        func plan(_ launch: String, stage: String = "FROM scratch AS only") throws -> BuildPlan {
            let (planner, _, bundle) = try planner("""
            \(stage)
            \(launch)
            """)
            return try planner.plan(edition: bundle.manifest.editions[0].id, target: "only",
                                    conditions: BuildConditions(arch: "arm64", macos: 15))
        }
        let launch = try #require(try plan("LAUNCH --env MODE=demo /MacOS/tool level-2").launch)
        #expect(launch.program == "/MacOS/tool")
        #expect(launch.environment == ["MODE": "demo"])
        #expect(launch.arguments == ["level-2"])
        #expect(launch.module == nil && launch.launcher() == nil)
        #expect(Composition(launch: launch) == Composition(launcher: nil))
        // Even in a stage that uses ScummVM, whose type claims no bare path.
        let inScummVM = try #require(try plan("LAUNCH /MacOS/tool", stage: "FROM scratch AS only\nUSE scummvm").launch)
        #expect(inScummVM.module == nil)
        // A folder is no program.
        #expect(throws: BuildPlanner.PlanError.self) { try plan("LAUNCH /MacOS/") }
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
        #expect(try steps("FROM scratch AS only\nUSE wine@10\nREMOVE C:/${module.wine.version}").flatMap(\.arguments) == ["wine:C:/10.0_8"])
        #expect(try steps("FROM scratch AS only\nUSE wine@10\nREMOVE C:/${wine.version}").flatMap(\.arguments) == ["wine:C:/10.0_8"])
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
