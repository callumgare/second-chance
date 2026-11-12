import Foundation
import Synchronization
import Testing
@testable import WrappModuleKit

@Suite("Module protocol order")
nonisolated struct RPCOrderTests {
    @Test("What the other end says before its reply has all been heard, in order, when the request returns")
    func notificationsBeforeReply() async throws {
        // The other end is played by hand rather than by a second connection:
        // a module's program is a process of its own. It answers each request
        // with its notifications and its reply in one write, so they arrive
        // together, as a program's last `emit` and its step's reply can.
        let toProgram = Pipe(), fromProgram = Pipe()
        let heard = Mutex<[Int]>([])
        let build = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting) { method, params in
            guard method == "emit", let params else { return nil }
            let number = try JSONDecoder().decode(Int.self, from: params)
            heard.withLock { $0.append(number) }
            return nil
        }
        let count = 500
        let rounds = 5
        let program = Thread {
            let requests = toProgram.fileHandleForReading
            var buffer = Data()
            for _ in 0..<rounds {
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
                for number in 0..<count {
                    guard let line = try? JSONEncoder().encode(RPCMessage(method: "emit", params: try? RawJSON(number))) else { return }
                    answer.append(line)
                    answer.append(UInt8(ascii: "\n"))
                }
                guard let reply = try? JSONEncoder().encode(RPCMessage(id: id, result: RawJSON(data: Data("null".utf8)))) else { return }
                answer.append(reply)
                answer.append(UInt8(ascii: "\n"))
                fromProgram.fileHandleForWriting.write(answer)
            }
        }
        program.start()

        // Several times over, as a race shows only sometimes.
        for round in 0..<rounds {
            heard.withLock { $0 = [] }
            _ = try await build.request("run", Nothing(), as: Nothing?.self)
            #expect(heard.withLock { $0 } == Array(0..<count), "round \(round)")
        }
        build.close()
        try toProgram.fileHandleForWriting.close()
        try fromProgram.fileHandleForWriting.close()
    }
}
