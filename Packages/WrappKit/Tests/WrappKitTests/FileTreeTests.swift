import Foundation
import Testing
@testable import ProcessKit

struct FileTreeTests {
    /// A folder like a disc kept in a wrapp before 2026-11-13: the folder
    /// itself and a folder in it read-only, with read-only files.
    private func readOnlyTree() throws -> (work: URL, tree: URL) {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("FileTreeTests-\(UUID().uuidString)")
        let tree = work.appendingPathComponent("disk-1")
        try files.createDirectory(at: tree.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tree.appendingPathComponent("Setup.exe"))
        try Data("b".utf8).write(to: tree.appendingPathComponent("Data/game.cab"))
        try files.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: work)
        for file in ["Setup.exe", "Data/game.cab"] {
            try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tree.appendingPathComponent(file).path)
        }
        for folder in [tree.appendingPathComponent("Data"), tree] {
            try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        return (work, tree)
    }

    private func cleanUp(_ work: URL) {
        try? FileTree.makeOwnerWritable(work)
        try? FileManager.default.removeItem(at: work)
    }

    @Test("A tree with read-only folders is removed whole")
    func removesReadOnlyTree() throws {
        let (work, tree) = try readOnlyTree()
        defer { cleanUp(work) }
        // What FileManager alone does with it.
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: tree) }

        try FileTree.remove(tree)

        #expect(!FileManager.default.fileExists(atPath: tree.path))
        // The link's target, outside the tree, is left alone.
        #expect(FileManager.default.fileExists(atPath: work.path))
    }

    @Test("Making a tree owner-writable reaches its own folder and keeps the other permissions")
    func makesOwnerWritable() throws {
        let (work, tree) = try readOnlyTree()
        defer { cleanUp(work) }

        try FileTree.makeOwnerWritable(tree)

        for path in ["", "Data", "Setup.exe", "Data/game.cab"] {
            let url = path.isEmpty ? tree : tree.appendingPathComponent(path)
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            #expect(mode == (path.hasSuffix(".exe") || path.hasSuffix(".cab") ? 0o644 : 0o755), "\(path.isEmpty ? "the tree" : path)")
        }
    }

    @Test("Only a refusal for want of permission counts as one")
    func permissionErrors() {
        #expect(FileTree.isPermissionError(CocoaError(.fileWriteNoPermission)))
        #expect(FileTree.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(FileTree.isPermissionError(CocoaError(.fileWriteUnknown, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ])))
        #expect(!FileTree.isPermissionError(CocoaError(.fileNoSuchFile)))
        #expect(!FileTree.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    }
}
