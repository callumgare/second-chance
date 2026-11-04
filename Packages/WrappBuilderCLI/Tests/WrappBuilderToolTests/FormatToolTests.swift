import Foundation
import Testing
@testable import WrappBuilderTool

/// Finding the Wrappfiles in a folder: bundles' and modules' stages and
/// functions, and nothing else.
struct FormatToolTests {
    @Test func findsBundlesAndModulesWrappfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["a/b/Wrappfile", "m/stages/prefix", "m/functions/patch", "m/module.yaml", "m/functions/notes.md"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "FROM scratch\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let found = try WrappfileTool.wrappfiles(in: [root]).compactMap { $0.path.components(separatedBy: root.lastPathComponent + "/").last }
        #expect(found.sorted() == ["a/b/Wrappfile", "m/functions/patch", "m/stages/prefix"])
    }
}
