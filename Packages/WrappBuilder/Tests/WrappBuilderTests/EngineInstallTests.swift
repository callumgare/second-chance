import Foundation
import Testing
@testable import WrappBuilder

struct EngineInstallTests {
    /// A tree laid out as an engine's: a framework with its version links,
    /// a library beside the launcher's in Frameworks, and a program.
    private func engine(in folder: URL) throws -> EngineStore.Engine {
        let tree = folder.appendingPathComponent("tree-wine")
        let files = FileManager.default
        let framework = tree.appendingPathComponent("Frameworks/Engine.framework")
        try files.createDirectory(at: framework.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try Data("engine".utf8).write(to: framework.appendingPathComponent("Versions/A/Engine"))
        try files.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try files.createSymbolicLink(atPath: framework.appendingPathComponent("Engine").path, withDestinationPath: "Versions/Current/Engine")
        try Data("z".utf8).write(to: tree.appendingPathComponent("Frameworks/libz.1.dylib"))
        try files.createDirectory(at: tree.appendingPathComponent("SharedSupport/wine/bin"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: tree.appendingPathComponent("SharedSupport/wine/bin/wine"))
        try EngineTree.writeList(module: "wine", in: tree)
        return EngineStore.Engine(module: "wine", version: "1", hash: String(repeating: "a", count: 64), tree: tree, prepared: true)
    }

    /// A wrapp's Contents/ as the template leaves it: the launcher's own
    /// files, one of them in Frameworks.
    private func launcher(in folder: URL) throws -> URL {
        let contents = folder.appendingPathComponent("Game.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("helpers".utf8).write(to: contents.appendingPathComponent("Frameworks/in_process_helpers.dylib"))
        return contents
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("An installed engine sits beside the launcher's files, recorded, and is taken out leaving only them")
    func installAndRemove() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = try launcher(in: folder)
        let engine = try engine(in: folder)
        try EngineInstall.install(engine, into: contents)

        #expect(try String(contentsOf: contents.appendingPathComponent("SharedSupport/wine/bin/wine"), encoding: .utf8) == "bin")
        let current = contents.appendingPathComponent("Frameworks/Engine.framework/Versions/Current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == "A")
        #expect(EngineInstall.installed(in: contents) == [.init(module: "wine", version: "1", hash: engine.hash)])

        try EngineInstall.remove(module: "wine", from: contents)
        #expect(EngineInstall.installed(in: contents).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path) == ["in_process_helpers.dylib"])
        #expect(!FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport").path))
    }

    @Test("A framework signed after its engine was listed goes whole, its signature with it")
    func signedFrameworkGoesWhole() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = try launcher(in: folder)
        let engine = try engine(in: folder)
        // Signing the prepared engine adds what its list doesn't name.
        let signature = engine.tree.appendingPathComponent("Frameworks/Engine.framework/Versions/A/_CodeSignature")
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        try Data("signed".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        try EngineInstall.install(engine, into: contents)

        try EngineInstall.remove(module: "wine", from: contents)
        #expect(!FileManager.default.fileExists(atPath: contents.appendingPathComponent("Frameworks/Engine.framework").path))
    }

    @Test("Two engines install side by side, and taking one out leaves the other whole")
    func twoEngines() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = try launcher(in: folder)
        let other = folder.appendingPathComponent("tree-other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: other.appendingPathComponent("MacOS/other"))
        try EngineTree.writeList(module: "other", in: other)
        try EngineInstall.install(try engine(in: folder), into: contents)
        try EngineInstall.install(EngineStore.Engine(module: "other", version: "2", hash: String(repeating: "b", count: 64),
                                                     tree: other, prepared: false), into: contents)
        #expect(EngineInstall.installed(in: contents).map(\.module) == ["other", "wine"])

        try EngineInstall.remove(module: "wine", from: contents)
        #expect(EngineInstall.installed(in: contents).map(\.module) == ["other"])
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("MacOS/other").path))
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/engines/other.files").path))
    }

    @Test("Folders whose names begin alike are each cloned whole, whatever order they sort in")
    func foldersSortingAroundEachOther() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = try launcher(in: folder)
        let tree = folder.appendingPathComponent("tree-dosbox")
        for path in ["Resources/mapping/ASCII.TXT", "Resources/mapping-unicode.org/CP437.TXT", "MacOS/dosbox"] {
            let file = tree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
        }
        try EngineTree.writeList(module: "dosbox", in: tree)
        try EngineInstall.install(EngineStore.Engine(module: "dosbox", version: "1", hash: String(repeating: "c", count: 64),
                                                     tree: tree, prepared: true), into: contents)
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/mapping/ASCII.TXT").path))
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/mapping-unicode.org/CP437.TXT").path))
    }

    @Test("An engine file with a launcher file's name stops the install")
    func collision() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = try launcher(in: folder)
        let engine = try engine(in: folder)
        try Data("theirs".utf8).write(to: engine.tree.appendingPathComponent("Frameworks/in_process_helpers.dylib"))
        try EngineTree.writeList(module: "wine", in: engine.tree)
        #expect(throws: EngineError.self) { try EngineInstall.install(engine, into: contents) }
        #expect(try String(contentsOf: contents.appendingPathComponent("Frameworks/in_process_helpers.dylib"), encoding: .utf8) == "helpers")
    }
}
