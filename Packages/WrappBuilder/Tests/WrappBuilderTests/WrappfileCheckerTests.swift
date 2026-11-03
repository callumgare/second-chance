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
    ARG install-dir="C:/Nancy Drew/Secret of the Old Clock"
    FROM scratch AS prefix
    USE wine@10
    FROM prefix AS disc
    ARG install-dir
    USE installer
    USE nancy-drew AS nd
    WINE.KEEP-DISCS --into=C:/nancy-drew-installer
    INSTALLER.RUN --from=disc-1 --into=${install-dir} --answer-file=${assets/disc.iss} --stubborn
    DO nd.patch --id=x --into=${install-dir}
    FROM prefix AS her-download
    ARG install-dir
    USE her-download
    HER-DOWNLOAD.INSTALL installer --into=${install-dir}
    """

    @Test func aValidWrappfileHasNoProblems() throws {
        #expect(try problems(Self.valid) == [])
    }

    @Test(arguments: [
        ("WINE.KEEP-DISCS --into=C:/nancy-drew-installer", "WINE.KEEP-DISCS --into=C:/x --cdrom",
         "line 8: WINE.KEEP-DISCS takes no --cdrom"),
        ("USE nancy-drew AS nd", "USE nancy-drew", "line 10: DO nd.patch: the stage doesn't USE a module called nd"),
        ("USE wine@10", "USE wine@11", "line 3: USE wine@11: no version of wine is 11"),
        ("DO nd.patch --id=x --into=${install-dir}", "DO nd.patch --id=x", "line 10: DO nd.patch needs --into"),
        ("DO nd.patch --id=x --into=${install-dir}", "DO nd.nothing", "line 10: DO nd.nothing: the nancy-drew module has no function called nothing"),
        ("${assets/disc.iss}", "${assets/missing.iss}", "line 9: ${assets/missing.iss}: the bundle has no assets/missing.iss"),
        ("FROM prefix AS her-download\nARG install-dir", "FROM prefix AS her-download",
         "line 13: ${install-dir}: nothing called install-dir is brought into the stage (ARG install-dir)"),
        ("--from=disc-1", "--from=disc-9", "line 9: INSTALLER.RUN --from=disc-9, but no edition has an input called that"),
        ("FROM prefix AS disc", "FROM nowhere AS disc", "line 4: FROM nowhere, but no stage before it is called that"),
        ("USE installer", "USE installer\nRUN --mount=type=disk,id=disc-1 D:/setup.exe",
         "line 7: RUN --mount type=disk isn't a mount type"),
        ("USE installer", "USE installer\nRUN --mount=type=volume,source=x,target=C:/x C:/x.exe",
         "line 7: RUN --mount type=volume isn't a mount type"),
        // Paths: a short form no module of the stage claims, or a type the stage hasn't.
        ("FROM prefix AS her-download", "FROM scratch AS other\nCOPY --from=disc-1 . C:/x\nFROM prefix AS her-download",
         "line 12: COPY C:/x: no module of this stage handles C: paths (it uses none)"),
        ("USE installer", "USE installer\nRUN steam:x", "line 7: RUN steam:x: steam: paths are steam's, which the stage doesn't USE"),
        ("USE installer", "USE installer\nCOPY --from=disc-1 . steam:x", "line 7: COPY steam:x: a steam: path isn't a location"),
        ("USE installer", "USE installer\nREMOVE /../../x", "line 7: REMOVE /../../x: it goes above the app's top level"),
        // A module's options and mount fields.
        ("USE installer", "USE installer\nRUN --wine.nothing=1 C:/x.exe",
         "line 7: RUN --wine.nothing: the wine module adds no option nothing to RUN"),
        ("USE installer", "USE installer\nRUN --mount=type=source,from=disc-1,wine.letter=D: C:/x.exe",
         "line 7: RUN --mount=…,wine.letter=…: the wine module adds no field letter to a source mount"),
        ("USE installer", "USE installer\nRUN --mount=type=source,from=disc-1,steam.drive=D: C:/x.exe",
         "line 7: RUN --mount=…,steam.drive=…: the stage doesn't USE a module called steam"),
        // Names.
        ("FROM prefix AS disc", "FROM prefix AS 1disc", "line 4: stage name 1disc must start with a letter"),
        ("FROM prefix AS disc", "FROM prefix AS disc\nFROM prefix AS DISC", "two stages are called disc"),
        ("USE installer", "USE installer\nCOPY.RUN x", "line 7: COPY.RUN isn't an instruction: COPY is the core's"),
    ])
    func catches(_ original: String, _ replacement: String, _ expected: String) throws {
        #expect(Self.valid.contains(original))
        let found = try problems(Self.valid.replacingOccurrences(of: original, with: replacement))
        #expect(found.contains { $0.hasPrefix(expected) }, "\(found)")
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
        #expect(found.warnings.contains { $0.hasPrefix("line 4: stage name Disc is written in upper case") })
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
        COPY --from=disc-1 . C:/c
        """)
        #expect(checker.problems(file).filter { $0.hasPrefix("line") } == ["line 5: COPY C:/c: no module of this stage handles C: paths (it uses wine)"])
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
