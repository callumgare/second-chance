import Darwin
import Foundation
import Testing
@testable import WineExecutor

struct DiscCopyTests {
    @Test("A disc copied from a read-only folder can be deleted, its own folder included")
    func copyFromReadOnlyFolderCanBeDeleted() async throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("DiscCopyTests-\(UUID().uuidString)")
        let disc = work.appendingPathComponent("disc")
        let copy = work.appendingPathComponent("disk-1")
        try files.createDirectory(at: disc.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data("setup".utf8).write(to: disc.appendingPathComponent("Setup.exe"))
        try Data("data".utf8).write(to: disc.appendingPathComponent("Data/game.cab"))
        // As a CD's: every folder and file read-only, the root too.
        for path in ["Data/game.cab", "Setup.exe"] {
            try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: disc.appendingPathComponent(path).path)
        }
        for folder in [disc.appendingPathComponent("Data"), disc] {
            try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        defer {
            for folder in [disc, disc.appendingPathComponent("Data"), copy] {
                try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
            try? files.removeItem(at: work)
        }

        try await DiscCopy.copy(from: disc, to: copy, total: nil) { _ in }

        #expect(files.fileExists(atPath: copy.appendingPathComponent("Data/game.cab").path))
        try files.removeItem(at: copy)
        #expect(!files.fileExists(atPath: copy.path))
    }

    @Test("A hybrid disc's unreadable ._ associated file is left out of the copy, and nothing else is")
    func associatedFiles() {
        #expect(DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/._Acrobat Installer.exe", errno: EINVAL))
        #expect(DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/Data/._layer1.cxt", errno: EINVAL))
        // A read that failed for another reason is still a broken disc.
        #expect(!DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/._Acrobat Installer.exe", errno: EIO))
        // So is any other file that can't be read.
        #expect(!DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/Webmaster.exe", errno: EINVAL))
        #expect(!DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/._folder/Webmaster.exe", errno: EINVAL))
    }
}
