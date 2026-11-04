import Foundation
import Synchronization
import Testing
@testable import SecondChance

@Suite("Build pipeline reliability")
struct BuildPipelineReliabilityTests {
    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Publishes that overlap reach each subscriber in the order they were made")
    func busOrder() async {
        let bus = EventBus<Int>()
        let seen = Mutex<[Int]>([])
        await bus.subscribe { value in
            // Slow on the first, so the second publish arrives while it runs.
            if value == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            seen.withLock { $0.append(value) }
        }
        let first = Task { await bus.publish(0) }
        try? await Task.sleep(for: .milliseconds(20))
        await bus.publish(1)
        await first.value
        #expect(seen.withLock { $0 } == [0, 1])
    }

    @Test("A subscriber that publishes doesn't wait for itself")
    func busReentrant() async {
        let bus = EventBus<Int>()
        let seen = Mutex<[Int]>([])
        await bus.subscribe { value in
            seen.withLock { $0.append(value) }
            if value == 0 { await bus.publish(1) }
        }
        await bus.publish(0)
        // The nested publish is queued behind the one that made it, so it is
        // handled after this returns: wait for it, rather than a fixed time.
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.withLock({ $0.count }) < 2 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(seen.withLock { $0 } == [0, 1])
    }

    @Test("A disc is copied whole, writable, without its extended attributes")
    func discCopy() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("disc")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("DATA"), withIntermediateDirectories: true)
        let file = disc.appendingPathComponent("DATA/game.cab")
        try Data(repeating: 7, count: 300_000).write(to: file)
        _ = setxattr(file.path, "com.apple.FinderInfo", [UInt8](repeating: 1, count: 32), 32, 0, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)

        let copy = root.appendingPathComponent("copy")
        let reported = Mutex<Int64>(0)
        try await DiscCopy.copy(from: disc, to: copy, total: 300_000) { progress in
            reported.withLock { $0 = max($0, progress.copied) }
        }
        let copied = copy.appendingPathComponent("DATA/game.cab")
        #expect(try Data(contentsOf: copied).count == 300_000)
        #expect(getxattr(copied.path, "com.apple.FinderInfo", nil, 0, 0, 0) < 0)
        #expect(FileManager.default.isWritableFile(atPath: copied.path))
    }

    @Test("A disc's data copied into the app is merged, writable, without attributes or AppleDouble files")
    func copyContents() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("disc")
        try FileManager.default.createDirectory(at: disc.appendingPathComponent("INFO"), withIntermediateDirectories: true)
        let file = disc.appendingPathComponent("INFO/INFOPICS.CXT")
        try Data(repeating: 7, count: 4096).write(to: file)
        _ = setxattr(file.path, "com.apple.FinderInfo", [UInt8](repeating: 1, count: 32), 32, 0, 0)
        // How a hybrid disc's ISO side lists a Mac file's resource fork
        try Data(repeating: 1, count: 100).write(to: disc.appendingPathComponent("INFO/._ICON_"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: disc.appendingPathComponent("INFO").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: disc.appendingPathComponent("INFO").path) }

        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("INFO"), withIntermediateDirectories: true)
        try Data([0]).write(to: game.appendingPathComponent("INFO/kept.txt"))
        try await WrappBuildHelper(bus: EventBus<AppEvent>()).copyContents(of: disc, into: game)

        let copied = game.appendingPathComponent("INFO/INFOPICS.CXT")
        #expect(try Data(contentsOf: copied).count == 4096)
        #expect(getxattr(copied.path, "com.apple.FinderInfo", nil, 0, 0, 0) < 0)
        #expect(FileManager.default.isWritableFile(atPath: copied.path))
        #expect(FileManager.default.isWritableFile(atPath: game.appendingPathComponent("INFO").path))
        #expect(!FileManager.default.fileExists(atPath: game.appendingPathComponent("INFO/._ICON_").path))
        #expect(FileManager.default.fileExists(atPath: game.appendingPathComponent("INFO/kept.txt").path))
    }

    @Test("A file the disc copy can't read fails the copy, naming it, rather than being left out")
    func discCopyUnreadableFile() async throws {
        let root = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: root.appendingPathComponent("disc/locked.cif").path)
            try? FileManager.default.removeItem(at: root)
        }
        let disc = root.appendingPathComponent("disc")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: disc.appendingPathComponent("readable.cif"))
        let locked = disc.appendingPathComponent("locked.cif")
        try Data(repeating: 2, count: 1_000).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        do {
            try await DiscCopy.copy(from: disc, to: root.appendingPathComponent("copy"), total: nil) { _ in }
            Issue.record("A copy missing locked.cif succeeded")
        } catch let error as CocoaError {
            #expect((error.userInfo[NSFilePathErrorKey] as? String)?.hasSuffix("locked.cif") == true)
        }
    }

    @Test("A cancelled disc copy stops with CancellationError")
    func discCopyCancelled() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = root.appendingPathComponent("disc")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        for index in 0..<200 {
            try Data(repeating: 1, count: 100_000).write(to: disc.appendingPathComponent("file\(index)"))
        }
        let copying = Task {
            try await DiscCopy.copy(from: disc, to: root.appendingPathComponent("copy"), total: nil) { _ in }
        }
        copying.cancel()
        await #expect(throws: CancellationError.self) { try await copying.value }
    }

    @Test("A Windows-1252 file is read, and written back in the encoding it came in")
    func windowsText() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ini = root.appendingPathComponent("setup.ini")
        // "Nancy Drew®" in Windows-1252: ® is 0xAE, not valid UTF-8 alone.
        try Data([0x4E, 0x61, 0x6E, 0x63, 0x79, 0x20, 0x44, 0x72, 0x65, 0x77, 0xAE]).write(to: ini)
        let read = try #require(TextFile.read(ini))
        #expect(read.text == "Nancy Drew®")
        #expect(read.encoding == .windowsCP1252)
    }
}
