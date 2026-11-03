import Darwin
import Foundation
import Testing
@testable import WrappBuilder

struct EngineTreeTests {
    private func tree() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("SharedSupport/wine/bin"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: folder.appendingPathComponent("SharedSupport/wine/bin/wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("SharedSupport/wine/bin/wine").path)
        try Data("dll".utf8).write(to: folder.appendingPathComponent("SharedSupport/wine/d3d9.dll"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("SharedSupport/wine/current").path,
                                                   withDestinationPath: "bin")
        return folder
    }

    @Test("The hash ignores times and attributes a download or copy adds")
    func ignoresTimesAndOtherAttributes() throws {
        let folder = try tree()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try EngineTree.hash(of: folder)
        let dll = folder.appendingPathComponent("SharedSupport/wine/d3d9.dll")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: dll.path)
        #expect(setxattr(dll.path, "com.apple.quarantine", "0081;0;x;", 9, 0, 0) == 0)
        #expect(try EngineTree.hash(of: folder) == before)
    }

    @Test("The hash changes with a file's contents, its executable bit, a link's target and a signature attribute")
    func changesWithWhatMatters() throws {
        let folder = try tree()
        defer { try? FileManager.default.removeItem(at: folder) }
        var seen = [try EngineTree.hash(of: folder)]
        let dll = folder.appendingPathComponent("SharedSupport/wine/d3d9.dll")

        try Data("other".utf8).write(to: dll)
        seen.append(try EngineTree.hash(of: folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dll.path)
        seen.append(try EngineTree.hash(of: folder))
        let link = folder.appendingPathComponent("SharedSupport/wine/current")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "lib")
        seen.append(try EngineTree.hash(of: folder))
        #expect(setxattr(dll.path, "com.apple.cs.CodeDirectory", "abc", 3, 0, 0) == 0)
        seen.append(try EngineTree.hash(of: folder))
        #expect(Set(seen).count == seen.count)
    }

    @Test("A tree's list names its files and links, and itself, not its folders")
    func list() throws {
        let folder = try tree()
        defer { try? FileManager.default.removeItem(at: folder) }
        try EngineTree.writeList(module: "wine", in: folder)
        let list = try String(contentsOf: folder.appendingPathComponent("Resources/engines/wine.files"), encoding: .utf8)
        #expect(list == """
            Resources/engines/wine.files
            SharedSupport/wine/bin/wine
            SharedSupport/wine/current
            SharedSupport/wine/d3d9.dll

            """)
    }
}

struct MachOPatchTests {
    /// A thin 64-bit Mach-O to patch: the first slice of a system program,
    /// which is universal. It has only 48 bytes free after its load
    /// commands, so the names added here are short.
    private func thinBinary() throws -> URL {
        let fat = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        func bigEndian(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 << 8 | Int(fat[offset + $1]) }
        }
        try #require(bigEndian(0) == 0xcafe_babe, "/bin/ls isn't universal")
        let offset = bigEndian(8 + 8), size = bigEndian(8 + 12)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macho-\(UUID().uuidString)")
        try fat.subdata(in: offset..<(offset + size)).write(to: url)
        return url
    }

    @Test("A run path is added once, as install_name_tool -add_rpath would")
    func runPath() throws {
        let binary = try thinBinary()
        defer { try? FileManager.default.removeItem(at: binary) }
        let path = "@loader_path/F"
        #expect(try !MachOPatch.runPaths(of: binary).contains(path))
        #expect(try MachOPatch.addRunPath(binary, path: path))
        #expect(try MachOPatch.runPaths(of: binary).contains(path))
        #expect(try !MachOPatch.addRunPath(binary, path: path))
        #expect(try MachOPatch.runPaths(of: binary).filter { $0 == path }.count == 1)
    }

    @Test("A weak dependency is added once, keeping the ones it had")
    func weakDylib() throws {
        let binary = try thinBinary()
        defer { try? FileManager.default.removeItem(at: binary) }
        let before = try MachOPatch.dependencies(of: binary)
        #expect(before.contains("/usr/lib/libSystem.B.dylib"))
        #expect(try MachOPatch.addWeakDylib(binary, reference: "@rpath/h.dylib"))
        #expect(try MachOPatch.dependencies(of: binary) == before + ["@rpath/h.dylib"])
        #expect(try !MachOPatch.addWeakDylib(binary, reference: "@rpath/h.dylib"))
    }

    @Test("A command with no room for it is refused, leaving the file as it was")
    func noRoom() throws {
        let binary = try thinBinary()
        defer { try? FileManager.default.removeItem(at: binary) }
        let before = try Data(contentsOf: binary)
        #expect(throws: EngineError.self) { try MachOPatch.addWeakDylib(binary, reference: WineBuild.helpersReference) }
        #expect(try Data(contentsOf: binary) == before)
    }

    @Test("A file that isn't Mach-O is refused")
    func notMachO() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-macho-\(UUID().uuidString)")
        try Data(repeating: 0, count: 64).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: EngineError.self) { try MachOPatch.addRunPath(file, path: "@loader_path") }
    }
}

struct EnginePackageTests {
    @Test("Each engine module's newest version has a package with its prepared hash and the sources its Swift asks for",
          arguments: [("wine", ["wine", "wineskin"]), ("scummvm", ["scummvm"])])
    func shippedPackages(module id: String, sources: [String]) throws {
        let module = try #require(try ModuleLoader(root: modulesRoot).module(id))
        let (_, package) = try #require(module.manifest.package())
        #expect(package.prepared != nil)
        #expect(package.sources.map(\.id) == sources)
        for source in package.sources {
            #expect(source.request.urls.count == source.urls.count, "\(source.id): a URL doesn't parse")
        }
    }

    @Test("A module with no engine has no package")
    func noPackage() throws {
        let module = try #require(try ModuleLoader(root: modulesRoot).module("steam"))
        #expect(module.manifest.package() == nil)
    }
}
