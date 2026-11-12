import Foundation
import Testing
@testable import WineKit

/// A drive that can't be set says which step failed and what was in the way.
@Suite("Wine drive failures")
struct WineDriveFailureTests {
    /// A wrapp's prefix of its own, removed afterwards with any folder made
    /// read-only by a test writable again first.
    private final class Prefix {
        let wrapp = FileManager.default.temporaryDirectory.appendingPathComponent("WineDrives-\(UUID().uuidString).app")
        lazy var wine = Wine(wrapp: wrapp)
        var lockedFolders: [URL] = []

        init() throws {
            try FileManager.default.createDirectory(at: Wine(wrapp: wrapp).prefix, withIntermediateDirectories: true)
        }

        func lock(_ folder: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            lockedFolders.append(folder)
        }

        deinit {
            for folder in lockedFolders {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
            try? FileManager.default.removeItem(at: wrapp)
        }
    }

    @Test("A file where the drives folder goes fails making it, and says a file was there")
    func drivesFolderIsAFile() throws {
        let prefix = try Prefix()
        let drives = prefix.wine.drives
        FileManager.default.createFile(atPath: drives.folder.path, contents: nil)

        let thrown = #expect(throws: WineDrives.Failure.self) { try drives.mount("/tmp/saves", as: "a") }
        let failure = try #require(thrown)
        guard case .makingDrivesFolder(let detail) = failure else {
            Issue.record("Expected makingDrivesFolder, got \(failure)")
            return
        }
        #expect(detail.entry == "dosdevices")
        #expect(detail.found == .file)
        #expect(detail.foundAbove == .folder)
        #expect(failure.reportTags == ["drive_entry": "dosdevices", "found": "file", "found_above": "folder"])
        // The system's error is the cause, and what the player is shown.
        let underlying = try #require((failure as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
        #expect(underlying.domain == NSCocoaErrorDomain)
        #expect(failure.localizedDescription == detail.underlying.localizedDescription)
    }

    @Test("A drives folder that can't be written fails making the entry")
    func entryCantBeMade() throws {
        let prefix = try Prefix()
        let drives = prefix.wine.drives
        try FileManager.default.createDirectory(at: drives.folder, withIntermediateDirectories: true)
        try prefix.lock(drives.folder)

        let thrown = #expect(throws: WineDrives.Failure.self) { try drives.mount("/tmp/saves", as: "a") }
        let failure = try #require(thrown)
        guard case .makingEntry(let detail) = failure else {
            Issue.record("Expected makingEntry, got \(failure)")
            return
        }
        #expect(detail.entry == "a:")
        #expect(detail.found == .nothing)
        #expect(detail.foundAbove == .folder)
    }

    @Test("A folder at the drive's name that can't be removed fails putting the entry in place")
    func entryCantBePlaced() throws {
        let prefix = try Prefix()
        let drives = prefix.wine.drives
        let stuck = drives.link("a").appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stuck.appendingPathComponent("file").path, contents: nil)
        try prefix.lock(stuck)

        let thrown = #expect(throws: WineDrives.Failure.self) { try drives.mount("/tmp/saves", as: "a") }
        let failure = try #require(thrown)
        guard case .placingEntry(let detail) = failure else {
            Issue.record("Expected placingEntry, got \(failure)")
            return
        }
        #expect(detail.entry == "a:")
        #expect(detail.found == .folder)
        // Nothing is left under its temporary name.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: drives.folder.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test("What is at a path is told without following a link there")
    func found() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Found-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let path = { (name: String) in folder.appendingPathComponent(name).path }
        try FileManager.default.createSymbolicLink(atPath: path("to-folder"), withDestinationPath: folder.path)
        try FileManager.default.createSymbolicLink(atPath: path("to-file"), withDestinationPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: path("broken"), withDestinationPath: path("gone"))

        #expect(WineDrives.Found.at(folder.path) == .folder)
        #expect(WineDrives.Found.at(file.path) == .file)
        #expect(WineDrives.Found.at(path("to-folder")) == .linkToFolder)
        #expect(WineDrives.Found.at(path("to-file")) == .linkToFile)
        #expect(WineDrives.Found.at(path("broken")) == .brokenLink)
        #expect(WineDrives.Found.at(path("gone")) == .nothing)
        #expect(WineDrives.Found.at(file.appendingPathComponent("below").path) == .nothing)
    }

    @Test("The log lists the drives folder's entries and where links go")
    func inventory() throws {
        let prefix = try Prefix()
        let drives = prefix.wine.drives
        try drives.mount("/tmp/saves", as: "a")
        drives.block("z")
        let listed = drives.inventory()
        #expect(listed.contains("a: broken-link → /tmp/saves") || listed.contains("a: link-to-folder → /tmp/saves"))
        #expect(listed.contains("z: file"))
    }
}
