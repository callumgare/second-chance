import Foundation
import Synchronization
import Testing
@testable import WrappModuleKit

/// A module's program, played by a thread rather than a second connection,
/// as a program is a process of its own: it answers each request with
/// `emits` notifications and its reply, in one write.
nonisolated func answeringProgram(requests: FileHandle, replies: FileHandle, emits: Int) -> Thread {
    Thread {
        var buffer = Data()
        while true {
            while !buffer.contains(UInt8(ascii: "\n")) {
                let chunk = requests.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
            }
            guard let end = buffer.firstIndex(of: UInt8(ascii: "\n")),
                  let request = try? JSONDecoder().decode(RPCMessage.self, from: buffer[buffer.startIndex..<end]),
                  let id = request.id else { return }
            buffer.removeSubrange(buffer.startIndex...end)
            var answer = Data()
            for number in 0..<emits {
                guard let line = try? JSONEncoder().encode(RPCMessage(method: "emit", params: try? RawJSON(number))) else { return }
                answer.append(line)
                answer.append(UInt8(ascii: "\n"))
            }
            guard let reply = try? JSONEncoder().encode(RPCMessage(id: id, result: RawJSON(data: Data("null".utf8)))) else { return }
            answer.append(reply)
            answer.append(UInt8(ascii: "\n"))
            replies.write(answer)
        }
    }
}

@Suite("Module protocol connections")
nonisolated struct RPCConnectionTests {
    @Test("A program that says nothing holds up no other connection in the process", .timeLimit(.minutes(1)))
    func aQuietProgramHoldsUpNoOther() async throws {
        // Each connection's read waited on a thread only one could hold at
        // a time, so the quiet one's left the other's answer unread.
        let quietOut = Pipe(), quietIn = Pipe()
        let quiet = RPCConnection(input: quietIn.fileHandleForReading, output: quietOut.fileHandleForWriting)
        try await Task.sleep(for: .milliseconds(200))  // its read under way first
        let toProgram = Pipe(), fromProgram = Pipe()
        let build = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting) { _, _ in nil }
        answeringProgram(requests: toProgram.fileHandleForReading, replies: fromProgram.fileHandleForWriting, emits: 1).start()
        _ = try await build.request("run", Nothing(), as: Nothing?.self)
        quiet.close()
        build.close()
        try toProgram.fileHandleForWriting.close()
        try fromProgram.fileHandleForWriting.close()
        try quietIn.fileHandleForWriting.close()
    }

    @Test("Both ends of a conversation can be in one process", .timeLimit(.minutes(1)))
    func bothEndsInOneProcess() async throws {
        let toProgram = Pipe(), fromProgram = Pipe()
        let heard = Mutex(0)
        let build = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting) { _, _ in
            heard.withLock { $0 += 1 }
            return nil
        }
        let program = RPCConnection(input: toProgram.fileHandleForReading, output: fromProgram.fileHandleForWriting)
        program.setHandler { _, _ in
            for number in 0..<100 { program.notify("emit", number) }
            return nil
        }
        for _ in 0..<5 { _ = try await build.request("run", Nothing(), as: Nothing?.self) }
        #expect(heard.withLock { $0 } == 500)
        build.close()
        program.close()
        try toProgram.fileHandleForWriting.close()
        try fromProgram.fileHandleForWriting.close()
    }

    @Test("A long conversation is heard to its end", .timeLimit(.minutes(1)))
    func aLongConversation() async throws {
        // The handler, kept in its Mutex as an optional, gained a thunk each
        // time it was called, so each message took longer than the last and
        // freeing the chain overflowed the stack: this crashed. No timing
        // is checked, which a busy Mac would fail.
        let toProgram = Pipe(), fromProgram = Pipe()
        let heard = Mutex(0)
        let build = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting) { _, _ in
            heard.withLock { $0 += 1 }
            return nil
        }
        answeringProgram(requests: toProgram.fileHandleForReading, replies: fromProgram.fileHandleForWriting, emits: 1000).start()
        for _ in 0..<20 { _ = try await build.request("run", Nothing(), as: Nothing?.self) }
        #expect(heard.withLock { $0 } == 20_000)
        build.close()
        try toProgram.fileHandleForWriting.close()
        try fromProgram.fileHandleForWriting.close()
    }

    @Test("A last line with no line break is still read")
    func lastLineWithoutBreak() async throws {
        let toProgram = Pipe(), fromProgram = Pipe()
        let heard = Mutex<[Int]>([])
        let closed = AsyncStream<Void>.makeStream()
        let build = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting) { _, params in
            if let params { heard.withLock { $0.append((try? JSONDecoder().decode(Int.self, from: params)) ?? -1) } }
            return nil
        }
        build.whenClosed { closed.continuation.finish() }
        var lines = Data()
        for number in [1, 2] {
            lines.append(try JSONEncoder().encode(RPCMessage(method: "emit", params: try RawJSON(number))))
            lines.append(contentsOf: Array("\r\n".utf8))
        }
        lines.append(try JSONEncoder().encode(RPCMessage(method: "emit", params: try RawJSON(3))))
        fromProgram.fileHandleForWriting.write(lines)
        try fromProgram.fileHandleForWriting.close()
        for await _ in closed.stream {}
        #expect(heard.withLock { $0 } == [1, 2, 3])
        try toProgram.fileHandleForWriting.close()
    }
}
