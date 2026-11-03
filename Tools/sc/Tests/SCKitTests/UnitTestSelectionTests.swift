import Foundation
import Testing
@testable import SCKit

@Suite("Picking unit suites by name")
struct UnitTestSelectionTests {
    /// A repo with a suite in the app's tests, one in a package's, one in
    /// sc's own, and an integration suite.
    private func repo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-unit-selection-\(UUID().uuidString)")
        let files = [
            "SecondChanceTests/DocsTableTests.swift": "struct DocsTableTests {}",
            "SecondChanceTests/Integration/DiskInstallIntegrationTests.swift": "struct DiskInstallIntegrationTests {}",
            "Packages/WrappKit/Tests/WrappKitTests/CompositionTests.swift": "@Suite struct CompositionTests {}",
            // A name only in a string, or a longer one, is no declaration of it.
            "Tools/sc/Tests/SCKitTests/ParsingTests.swift": "struct ParsingTests {}\nstruct DocsTableTestsHelper {}\nlet x = \"struct DocsTableTests {}\"",
        ]
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return root
    }

    @Test("Each suite runs where it's declared, and a test in one with it")
    func findsEachSuite() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try UnitTestSelection.locate(
            ["DocsTableTests/everyDocHasARow()", "CompositionTests", "ParsingTests"], root: root,
            packages: ["WrappKit", "WrappBuilder"], integrationSuites: ["DiskInstallIntegrationTests"])
        #expect(selection == UnitTestSelection(app: ["DocsTableTests/everyDocHasARow()"],
                                               packages: ["WrappKit": ["CompositionTests"]], tool: ["ParsingTests"]))
    }

    @Test("A name that's nowhere, or an integration suite's, is refused")
    func refusesWhatIsNotAUnitSuite() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["NoSuchTests", "DocsTable", "DiskInstallIntegrationTests"] {
            #expect(throws: SCError.self) {
                try UnitTestSelection.locate([name], root: root, packages: ["WrappKit"], integrationSuites: ["DiskInstallIntegrationTests"])
            }
        }
    }
}
