import Foundation
import Testing
@testable import ProcessKit

/// Running a program to completion with `Process.output(of:_:)`: what it
/// wrote to each stream, its status, and that it answers when the program
/// exits rather than when its pipes close.
@Suite("Process output")
struct ProcessOutputTests {
    @Test("Both streams and the exit status come back, each in its own")
    func bothStreams() async throws {
        let result = try await Process.output(of: "/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.output == "out\n")
        #expect(result.errorOutput == "err\n")
        #expect(result.status == 3)
        #expect(!result.succeeded)
    }

    @Test("More than a pipe holds, on both streams at once, comes back whole")
    func moreThanAPipeHolds() async throws {
        let script = "head -c 1000000 /dev/zero | tr '\\0' a; head -c 1000000 /dev/zero | tr '\\0' b >&2"
        let result = try await Process.output(of: "/bin/sh", ["-c", script])
        #expect(result.output.count == 1_000_000)
        #expect(result.errorOutput.count == 1_000_000)
        #expect(result.output.allSatisfy { $0 == "a" })
    }

    /// As actool does on a Mac where its `ibtoold` isn't running yet: the
    /// daemon it starts inherits its pipes and holds them open long after
    /// actool has gone. Waiting for the pipes' end hung CI's unit tests.
    @Test("A program that leaves a child holding its pipes is answered when it exits")
    func childHoldingThePipes() async throws {
        let started = ContinuousClock.now
        let result = try await Process.output(of: "/bin/sh", ["-c", "echo done; sleep 60 & echo $! >&2"])
        #expect(result.output == "done\n")
        #expect(ContinuousClock.now - started < .seconds(30))
        if let child = Int32(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(child, SIGKILL) }
    }

    @Test("A program that can't be started throws")
    func cantStart() async {
        await #expect(throws: (any Error).self) {
            try await Process.output(of: "/nonexistent/program", [])
        }
    }
}
