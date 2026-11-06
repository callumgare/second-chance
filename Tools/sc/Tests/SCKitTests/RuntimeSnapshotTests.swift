import Foundation
@testable import SCKit
import Testing

@Suite("Runtime copy snapshots")
struct RuntimeSnapshotTests {
    /// A runtime copy with a little of everything a snapshot clones or links.
    static func makeCopy() throws -> URL {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("sc snapshot \(UUID().uuidString)")
        for (path, text) in [(Repo.runtimeMarker, "copy"), ("sc", "#!/bin/bash"), (".sc/sc", "binary"), ("Bundles/a.yaml", "a"),
                             ("Modules/b.yaml", "b"), ("DerivedData/Build/Products/Debug/app", "app"), ("built-apps/game.app", "game"),
                             (".env", "SETTING=1")] {
            let file = copy.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return copy
    }

    @discardableResult
    static func bash(_ script: String, in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Make a snapshot as `--on` would, synced and started: its path.
    static func makeSnapshot(of copy: URL, started: Bool = true) throws -> URL {
        let relative = try bash(RuntimeSnapshot.createScript(copyPath: copy.path), in: copy).trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = copy.appendingPathComponent(relative)
        try bash(RuntimeSnapshot.recordScript, in: snapshot)
        if started { RuntimeSnapshot.markStarted(environment: ["SC_REPO_ROOT": snapshot.path]) }
        return snapshot
    }

    static func collect(_ copy: URL) throws -> [RuntimeSnapshot.Changed] {
        RuntimeSnapshot.parseCollect(try bash(RuntimeSnapshot.collectScript(copyPath: copy.path), in: copy))
    }

    @Test("A snapshot clones the build and data and links what runs keep to the copy")
    func layout() throws {
        let copy = try Self.makeCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        let snapshot = try Self.makeSnapshot(of: copy, started: false)
        let fm = FileManager.default
        #expect(try String(contentsOf: snapshot.appendingPathComponent("DerivedData/Build/Products/Debug/app"), encoding: .utf8) == "app")
        #expect(try String(contentsOf: snapshot.appendingPathComponent(".sc/sc"), encoding: .utf8) == "binary")
        #expect(fm.fileExists(atPath: snapshot.appendingPathComponent(Repo.runtimeMarker).path))
        #expect(fm.fileExists(atPath: snapshot.appendingPathComponent(RuntimeSnapshot.pendingFile).path))
        // Not the snapshots inside the copy's .sc.
        #expect(!fm.fileExists(atPath: snapshot.appendingPathComponent(RuntimeSnapshot.folder).path))
        for item in ["built-apps", "test-results", ".local", "DerivedData/sc-jobs", "DerivedData/sc-logs", ".env"] {
            let destination = try fm.destinationOfSymbolicLink(atPath: snapshot.appendingPathComponent(item).path)
            #expect(URL(fileURLWithPath: destination).resolvingSymlinksInPath() == copy.appendingPathComponent(item).resolvingSymlinksInPath())
        }
        // What a run writes through a link lands in the copy.
        try "new".write(to: snapshot.appendingPathComponent("built-apps/new.app"), atomically: true, encoding: .utf8)
        #expect(fm.fileExists(atPath: copy.appendingPathComponent("built-apps/new.app").path))
    }

    @Test("Collecting keeps a snapshot whose sc hasn't started, and removes an unchanged one nothing runs from")
    func collectsUnused() throws {
        let copy = try Self.makeCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        let pending = try Self.makeSnapshot(of: copy, started: false)
        let finished = try Self.makeSnapshot(of: copy)
        // Written through a link: the copy's, so no change to the snapshot.
        try "made".write(to: finished.appendingPathComponent("DerivedData/sc-logs/run.log"), atomically: true, encoding: .utf8)
        #expect(try Self.collect(copy).isEmpty)
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: finished.path))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("DerivedData/sc-logs/run.log").path))
    }

    @Test("Collecting keeps a snapshot something still runs from")
    func keepsInUse() throws {
        let copy = try Self.makeCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        let snapshot = try Self.makeSnapshot(of: copy)
        // A process whose command line names the snapshot, as its sc's does
        // (`; true` keeps sh from handing its process to sleep).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30; true", snapshot.appendingPathComponent(".sc/sc").path]
        try process.run()
        defer { process.terminate() }
        #expect(try Self.collect(copy).isEmpty)
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test("Collecting keeps a snapshot with changes of its own, and names them")
    func keepsChanged() throws {
        let copy = try Self.makeCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        let snapshot = try Self.makeSnapshot(of: copy)
        try "stray".write(to: snapshot.appendingPathComponent("default.profraw"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("Bundles/a.yaml"))
        let changed = try Self.collect(copy)
        #expect(changed.count == 1)
        #expect(changed.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() } == snapshot.resolvingSymlinksInPath())
        let differences = changed.first?.differences ?? []
        #expect(differences.contains { $0.hasPrefix(">") && $0.hasSuffix("./default.profraw") })
        #expect(differences.contains { $0.hasPrefix("<") && $0.hasSuffix("./Bundles/a.yaml") })
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test("A finished run's changes in its snapshot are listed, and many are cut short")
    func changesAtTheEnd() async throws {
        let copy = try Self.makeCopy()
        defer { try? FileManager.default.removeItem(at: copy) }
        let snapshot = try Self.makeSnapshot(of: copy)
        // Through a link, so not the snapshot's.
        try "log".write(to: snapshot.appendingPathComponent("DerivedData/sc-logs/run.log"), atomically: true, encoding: .utf8)
        #expect(await RuntimeSnapshot.changes(in: snapshot) == [])

        try "stray".write(to: snapshot.appendingPathComponent("default.profraw"), atomically: true, encoding: .utf8)
        let one = try #require(await RuntimeSnapshot.changes(in: snapshot))
        #expect(one.count == 1)
        #expect(one.first?.hasPrefix(">") == true && one.first?.hasSuffix("./default.profraw") == true)

        for index in 0..<25 {
            try "x".write(to: snapshot.appendingPathComponent("stray-\(index)"), atomically: true, encoding: .utf8)
        }
        let many = try #require(await RuntimeSnapshot.changes(in: snapshot))
        #expect(many.count == RuntimeSnapshot.shownChanges + 1)
        #expect(many.last == "more \(26 - RuntimeSnapshot.shownChanges)")
    }

    @Test("A snapshot is told from a copy by its path")
    func isSnapshot() {
        #expect(RuntimeSnapshot.isSnapshot(URL(fileURLWithPath: "/u/tmp/sc/.sc/snapshots/20261106-1-2")))
        #expect(!RuntimeSnapshot.isSnapshot(URL(fileURLWithPath: "/u/tmp/sc")))
    }

    @Test("A GUI-session job records the root it runs in, for attach")
    func jobRecordsRoot() throws {
        let jobs = FileManager.default.temporaryDirectory.appendingPathComponent("sc jobs \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: jobs) }
        let root = URL(fileURLWithPath: "/u/tmp/sc/.sc/snapshots/20261106-1-2")
        #expect(try LaunchAgentJob(command: ["true"], in: jobs, root: root).root == root)
        #expect(try LaunchAgentJob(command: ["true"], in: jobs, now: Date(timeIntervalSince1970: 0)).root == nil)
    }

    @Test("Collecting's output is read into each kept snapshot and its differences")
    func parsesCollect() {
        let output = "changed /a/one\n  > 1 2 ./x\n  < 1 2 ./y\nchanged /a/two\n  > 3 4 ./z\n"
        #expect(RuntimeSnapshot.parseCollect(output) == [
            RuntimeSnapshot.Changed(path: "/a/one", differences: ["> 1 2 ./x", "< 1 2 ./y"]),
            RuntimeSnapshot.Changed(path: "/a/two", differences: ["> 3 4 ./z"]),
        ])
        #expect(RuntimeSnapshot.parseCollect("").isEmpty)
    }
}
