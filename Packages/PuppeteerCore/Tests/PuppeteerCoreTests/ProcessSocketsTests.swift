import Darwin
import Foundation
import Testing
@testable import PuppeteerCore

/// Finding the processes a run started by the sockets they serve.
@Suite("Process sockets")
struct ProcessSocketsTests {
    @Test("The PID is read from the socket's name", arguments: [
        ("game-123.sock", Int32(123)),
        ("game-1.sock", Int32(1)),
    ])
    func readsPid(name: String, pid: Int32) {
        #expect(ProcessSockets.pid(fromSocketNamed: name, prefix: "game-") == pid)
    }

    @Test("Other names are not sockets of a process", arguments: [
        "wrapp.sock", "game-.sock", "game-12a.sock", "game-12.png", "game--4.sock", "game-0.sock",
        "game-99999999999.sock", "other-12.sock", "game-١٢.sock",
    ])
    func ignoresOtherNames(name: String) {
        #expect(ProcessSockets.pid(fromSocketNamed: name, prefix: "game-") == nil)
    }

    @Test("Only live processes' sockets count, lowest PID first")
    func listsLiveProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessSocketsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // This process is alive and launchd (1) is too; a PID past the
        // system's limit never is.
        let me = getpid()
        for name in ["game-\(me).sock", "game-1.sock", "game-\(Int32.max).sock", "wrapp.sock"] {
            #expect(FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil))
        }

        let pids = ProcessSockets.livePids(in: directory.path, prefix: "game-")
        // launchd is root's: kill(1, 0) fails with EPERM for anyone else, so
        // it reads as gone, as another user's process should.
        #expect(pids == [me])
    }

    @Test("A directory that isn't there has no sockets")
    func missingDirectory() {
        #expect(ProcessSockets.livePids(in: "/nonexistent-\(UUID().uuidString)", prefix: "game-").isEmpty)
    }
}
