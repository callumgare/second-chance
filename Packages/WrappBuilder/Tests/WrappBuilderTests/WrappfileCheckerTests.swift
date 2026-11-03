import Foundation
import Testing
@testable import WrappBuilder

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
    wine.KEEP-DISCS --into=C:/nancy-drew-installer
    installer.RUN --from=disc-1 --into=${install-dir} --answer-file=${assets/disc.iss} --stubborn
    DO nd.patch --id=x --into=${install-dir}
    FROM prefix AS her-download
    ARG install-dir
    USE her-download
    her-download.INSTALL installer --into=${install-dir}
    """

    @Test func aValidWrappfileHasNoProblems() throws {
        #expect(try problems(Self.valid) == [])
    }

    @Test(arguments: [
        ("wine.KEEP-DISCS --into=C:/nancy-drew-installer", "wine.KEEP-DISCS --into=C:/x --cdrom",
         "line 8: wine.KEEP-DISCS takes no --cdrom"),
        ("USE nancy-drew AS nd", "USE nancy-drew", "line 10: DO nd.patch: the stage doesn't USE a module called nd"),
        ("USE wine@10", "USE wine@11", "line 3: USE wine@11: no version of wine is 11"),
        ("DO nd.patch --id=x --into=${install-dir}", "DO nd.patch --id=x", "line 10: DO nd.patch needs --into"),
        ("DO nd.patch --id=x --into=${install-dir}", "DO nd.nothing", "line 10: DO nd.nothing: the nancy-drew module has no function called nothing"),
        ("${assets/disc.iss}", "${assets/missing.iss}", "line 9: ${assets/missing.iss}: the bundle has no assets/missing.iss"),
        ("FROM prefix AS her-download\nARG install-dir", "FROM prefix AS her-download",
         "line 13: ${install-dir}: nothing called install-dir is brought into the stage (ARG install-dir)"),
        ("--from=disc-1", "--from=disc-9", "line 9: installer.RUN --from=disc-9, but no edition has an input called that"),
        ("FROM prefix AS disc", "FROM nowhere AS disc", "line 4: FROM nowhere, but no stage before it is called that"),
        ("USE installer", "USE installer\nRUN --mount=type=disk,id=disc-1 D:/setup.exe",
         "line 7: RUN --mount type=disk isn't a mount type"),
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

    @Test func modulesFunctionsParseAndCheck() throws {
        let module = try #require(try shippedModules().first { $0.manifest.id == "nancy-drew" })
        for path in module.manifest.functions ?? [] {
            let file = try WrappfileParser.parse(String(contentsOf: module.file(path), encoding: .utf8))
            #expect(file.function(named: (path as NSString).lastPathComponent) != nil, "\(path)")
        }
    }
}
