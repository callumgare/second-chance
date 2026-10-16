import Testing
import Foundation
@testable import SecondChance

@Suite("Unused engine cleanup")
struct EngineCleanupTests {

    @Test("Listed entries go whole, with the symlinks that pointed into them")
    func removesWholeEntries() throws {
        let fm = FileManager.default
        let wrapp = fm.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString).app")
        let contents = wrapp.appendingPathComponent("Contents")
        defer { try? fm.removeItem(at: wrapp) }

        // A framework with the usual Versions/Current symlinks, a versioned
        // dylib with its unversioned symlink, and something to keep.
        let framework = contents.appendingPathComponent("Frameworks/Engine.framework")
        try fm.createDirectory(at: framework.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: framework.appendingPathComponent("Versions/A/Engine"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Engine").path, withDestinationPath: "Versions/Current/Engine")
        let frameworks = contents.appendingPathComponent("Frameworks")
        try Data("y".utf8).write(to: frameworks.appendingPathComponent("libz.1.3.1.dylib"))
        try fm.createSymbolicLink(atPath: frameworks.appendingPathComponent("libz.1.dylib").path, withDestinationPath: "libz.1.3.1.dylib")
        try Data("keep".utf8).write(to: frameworks.appendingPathComponent("libkeep.dylib"))

        let list = contents.appendingPathComponent("Resources/engine-files")
        try fm.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Frameworks/Engine.framework/Versions/A/Engine\nFrameworks/libz.1.3.1.dylib\n".write(to: list, atomically: true, encoding: .utf8)

        try WrappBuildHelper.shared.removeEngineFiles(listedIn: list, engine: "Test", from: wrapp)

        let left = try fm.contentsOfDirectory(atPath: frameworks.path).sorted()
        #expect(left == ["libkeep.dylib"])
    }
}
