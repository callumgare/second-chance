import Foundation
import Testing
@testable import WrappBuilder
import WrappModules

/// The checker catches what would otherwise fail mid-build, against Old
/// Clock's manifest and the shipped modules.
struct WrappfileCheckerTests {
    private func problems(_ wrappfile: String) throws -> [String] {
        let folder = bundlesRoot.appendingPathComponent("nancy-drew/old-clock")
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let manifest = try loader.load(folder).get().manifest
        return WrappfileChecker(manifest: manifest, bundleFolder: folder, modules: try shippedModules())
            .problems(try WrappfileParser.parse(wrappfile))
    }

    private static let valid = """
    CONST install-dir = "C:/Nancy Drew/Secret of the Old Clock"
    INPUT disc-1
    INPUT installer
    INPUT game
    FROM scratch AS prefix
    USE wine@10
    FROM prefix AS disc
    USE installer
    USE nancy-drew AS nd
    WINE.KEEP-DISCS ${input.disc-1} --into=C:/nancy-drew-installer
    INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} --answer-file=assets/disc.iss --automation=module:nancy-drew/assets/installshield-custom-dialog-automate.au3
    DO nd.patch --id=x --into=${const.install-dir}
    FROM prefix AS her-download
    USE her-download
    HER-DOWNLOAD.INSTALL ${input.installer} --into=${const.install-dir}
    FROM steam@1/client AS steam
    DO steam.install --game=${input.game} --into=${const.install-dir}
    FROM big-fish@1/manager AS big-fish
    DO big-fish.install --game=${input.game} --into=${const.install-dir}
    """

    @Test func aValidWrappfileHasNoProblems() throws {
        #expect(try problems(Self.valid) == [])
    }

    @Test(arguments: [
        ("WINE.KEEP-DISCS ${input.disc-1} --into=C:/nancy-drew-installer", "WINE.KEEP-DISCS ${input.disc-1} --into=C:/x --cdrom",
         "line 10: WINE.KEEP-DISCS takes no --cdrom"),
        ("USE nancy-drew AS nd", "USE nancy-drew", "line 12: DO nd.patch: the stage doesn't USE a module called nd"),
        ("USE wine@10", "USE wine@11", "line 6: USE wine@11: no version of wine is 11"),
        ("DO nd.patch --id=x --into=${const.install-dir}", "DO nd.patch --id=x", "line 12: DO nd.patch needs --into"),
        ("DO nd.patch --id=x --into=${const.install-dir}", "DO nd.nothing", "line 12: DO nd.nothing: the nancy-drew module has no function called nothing"),
        ("assets/disc.iss", "assets/missing.iss", "line 11: INSTALLER.RUN assets/missing.iss: the bundle has no assets/missing.iss"),
        ("--from=${input.disc-1}", "--from=${input.disc-9}", "line 11: INSTALLER.RUN ${input.disc-9}: no INPUT called disc-9 here"),
        ("--from=${input.disc-1}", "--from=disc-1", "line 11: INSTALLER.RUN disc-1: an input is written ${input.<name>}"),
        ("FROM prefix AS disc", "FROM nowhere AS disc", "line 7: FROM nowhere, but no stage before it is called that"),
        ("USE installer", "USE installer\nRUN --mount=type=disk,id=disc-1 D:/setup.exe",
         "line 9: RUN --mount type=disk isn't a mount type"),
        ("USE installer", "USE installer\nRUN --mount=type=volume,source=x,target=C:/x C:/x.exe",
         "line 9: RUN --mount type=volume isn't a mount type"),
        // Paths: a short form no module of the stage claims, or a type the stage hasn't.
        ("FROM prefix AS her-download", "FROM scratch AS other\nCOPY --from=${input.disc-1} . C:/x\nFROM prefix AS her-download",
         "line 14: COPY C:/x: no module of this stage handles C: paths (it uses none)"),
        ("USE installer", "USE installer\nRUN steam:x", "line 9: RUN steam:x: steam: paths are steam's, which the stage doesn't USE"),
        ("USE installer", "USE installer\nCOPY --from=${input.disc-1} . steam:x", "line 9: COPY steam:x: a steam: path isn't a location"),
        ("USE installer", "USE installer\nREMOVE /../../x", "line 9: REMOVE /../../x: it goes above the app's top level"),
        // A module's options and mount fields.
        ("USE installer", "USE installer\nRUN --wine.nothing=1 C:/x.exe",
         "line 9: RUN --wine.nothing: the wine module adds no option nothing to RUN"),
        ("USE installer", "USE installer\nRUN --mount=type=source,from=disc-1,wine.letter=D: C:/x.exe",
         "line 9: RUN --mount=…,wine.letter=…: the wine module adds no field letter to a source mount"),
        ("USE installer", "USE installer\nRUN --mount=type=source,from=disc-1,steam.drive=D: C:/x.exe",
         "line 9: RUN --mount=…,steam.drive=…: the stage doesn't USE a module called steam"),
        // Names.
        ("FROM prefix AS disc", "FROM prefix AS 1disc", "line 7: stage name 1disc must start with a letter"),
        ("FROM prefix AS disc", "FROM prefix AS disc\nFROM prefix AS DISC", "two stages are called disc"),
        ("USE installer", "USE installer\nCOPY.RUN x", "line 9: COPY.RUN isn't an instruction: COPY is the core's"),
        // Values: every reference names something declared, in any branch.
        ("USE installer", "USE installer\nIF ${platform.arch} = \"x\"\n  REMOVE ${const.typo}\nEND",
         "line 10: REMOVE ${const.typo}: no CONST called typo here"),
        ("USE installer", "USE installer\nREMOVE ${input.install-dir}", "line 9: REMOVE ${input.install-dir}: install-dir is a CONST"),
        ("USE installer", "USE installer\nREMOVE ${platform.cpu}", "line 9: REMOVE ${platform.cpu}: the platform has arch and macos"),
        ("USE nancy-drew AS nd", "USE nancy-drew AS nd\nREMOVE ${nd.data.nothing.x}",
         "line 10: REMOVE ${nd.data.nothing.x}: the nancy-drew module has no data table nothing"),
        ("USE nancy-drew AS nd", "USE nancy-drew AS nd\nREMOVE ${nd.data.patches[input.disc-1].ulr}",
         "line 10: REMOVE ${nd.data.patches[input.disc-1].ulr}: patches"),
        ("USE installer", "USE installer\nREMOVE ${self.data.x}", "line 9: REMOVE ${self.data.x}: self is only in a module's own files"),
        ("USE installer", "USE installer\nINPUT late", "line 9: INPUT late: an INPUT is declared before the first FROM"),
        ("USE installer", "USE installer\nSET install-dir = \"x\"", "line 9: SET install-dir: install-dir is a CONST, which can't be set"),
        ("USE installer", "USE installer\nSET nothing = \"x\"", "line 9: SET nothing, but there's no VAR called nothing"),
        ("USE installer", "USE installer\nCONST install-dir = \"x\"", "line 9: CONST install-dir: install-dir is a CONST already"),
    ])
    func catches(_ original: String, _ replacement: String, _ expected: String) throws {
        #expect(Self.valid.contains(original))
        let found = try problems(Self.valid.replacingOccurrences(of: original, with: replacement))
        #expect(found.contains { $0.hasPrefix(expected) }, "\(found)")
    }

    @Test("A function reads its caller's values only through its own INPUTs")
    func functionsReadOnlyTheirInputs() throws {
        let file = Self.valid + "\nFUNCTION f\n  INPUT x\n  REMOVE ${input.x}/${const.install-dir}\nEND"
        #expect(try problems(file).contains { $0.contains("${const.install-dir}: no CONST called install-dir here (a function reads") })
    }

    @Test("What nothing reads is warned about")
    func unusedWarnings() throws {
        let folder = bundlesRoot.appendingPathComponent("nancy-drew/old-clock")
        let manifest = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules()).load(folder).get().manifest
        let found = WrappfileChecker(manifest: manifest, bundleFolder: folder, modules: try shippedModules())
            .findings(try WrappfileParser.parse("CONST spare = \"x\"\n" + Self.valid))
        #expect(found.warnings.contains("line 1: CONST spare is never read"))
    }

    @Test func aTargetMustBeAStage() throws {
        let found = try problems(Self.valid.replacingOccurrences(of: "FROM prefix AS disc", with: "FROM prefix AS install"))
        #expect(found.contains("manifest.yaml's edition cd builds disc, which the Wrappfile has no stage called"))
    }

    @Test("A Wrappfile in lower case checks as one in upper case")
    func lowerCase() throws {
        let lower = Self.valid
            .replacingOccurrences(of: "FROM", with: "from").replacingOccurrences(of: " AS ", with: " as ")
            .replacingOccurrences(of: "USE", with: "use").replacingOccurrences(of: "WINE.KEEP-DISCS", with: "wine.keep-discs")
            .replacingOccurrences(of: "INSTALLER.RUN", with: "Installer.Run").replacingOccurrences(of: "DO nd.", with: "do ND.")
            .replacingOccurrences(of: "CONST", with: "const").replacingOccurrences(of: "INPUT", with: "input")
        #expect(try problems(lower) == [])
    }

    @Test("Upper-case names and modules named like core instructions are warned about, not refused")
    func warnings() throws {
        let file = Self.valid.replacingOccurrences(of: "FROM prefix AS disc", with: "FROM prefix AS Disc")
            .replacingOccurrences(of: "USE nancy-drew AS nd", with: "USE nancy-drew AS copy")
            .replacingOccurrences(of: "DO nd.patch", with: "DO copy.patch")
        let folder = bundlesRoot.appendingPathComponent("nancy-drew/old-clock")
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let manifest = try loader.load(folder).get().manifest
        let found = WrappfileChecker(manifest: manifest, bundleFolder: folder, modules: try shippedModules())
            .findings(try WrappfileParser.parse(file))
        #expect(found.errors == [])
        #expect(found.warnings.contains { $0.hasPrefix("line 7: stage name Disc is written in upper case") })
        #expect(found.warnings.contains { $0.contains("copy is a core instruction") })
    }

    @Test("Two modules claiming one short form clash in a stage; the full form settles it")
    func shortFormClash() throws {
        let folder = bundlesRoot.appendingPathComponent("nancy-drew/old-clock")
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let manifest = try loader.load(folder).get().manifest
        let checker = WrappfileChecker(manifest: manifest, bundleFolder: folder, modules: try shippedModules())
        let clash = try WrappfileParser.parse("FROM scratch AS x\nUSE wine\nUSE dosbox\nREMOVE C:/x")
        #expect(checker.problems(clash).contains { $0.hasPrefix("line 4: REMOVE C:/x: both wine and dosbox take C: paths here") })
        let full = try WrappfileParser.parse("FROM scratch AS x\nUSE wine\nUSE dosbox\nREMOVE dosbox:C:/x")
        #expect(!checker.problems(full).contains { $0.contains("REMOVE") })
    }

    @Test("A stub module's path types, options and mount fields, through the registry seams")
    func stubModules() throws {
        let folder = bundlesRoot.appendingPathComponent("nancy-drew/old-clock")
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: try shippedModules())
        let manifest = try loader.load(folder).get().manifest
        let types = PathTypeRegistry([PathType(name: "stub", module: "wine", roles: [.program], shortForm: .driveLetter)])
        let checker = WrappfileChecker(manifest: manifest, bundleFolder: folder, modules: try shippedModules(), pathTypes: types,
                                       native: { $0 == "wine" ? StubBuild.self : BuildModules.native($0) })
        let file = try WrappfileParser.parse("""
        FROM scratch AS x
        USE wine
        RUN --wine.desktop=on --mount=type=cache,wine.size=1 C:/a.exe
        RUN stub:C:/b.exe
        COPY --from=nothere . C:/c
        """)
        #expect(checker.problems(file).filter { $0.hasPrefix("line") }.sorted() == [
            "line 5: COPY --from=nothere, but there's no stage called that (an input is written ${input.<name>})",
            "line 5: COPY C:/c: no module of this stage handles C: paths (it uses wine)",
        ])
    }

    @Test func modulesFunctionsParseAndCheck() throws {
        let module = try #require(try shippedModules().first { $0.manifest.id == "nancy-drew" })
        for path in module.manifest.functions ?? [] {
            let file = try WrappfileParser.parse(String(contentsOf: module.file(path), encoding: .utf8))
            #expect(file.function(named: (path as NSString).lastPathComponent) != nil, "\(path)")
        }
    }
}

/// A module whose additions a test declares.
private enum StubBuild: BuildModule {
    static let id: ModuleID = "wine"
    static let coreOptions: [String: [String: InstructionSpec.OptionKind]] = ["RUN": ["desktop": .value]]
    static let mountFields: [String: Set<String>] = ["cache": ["size"]]
}
