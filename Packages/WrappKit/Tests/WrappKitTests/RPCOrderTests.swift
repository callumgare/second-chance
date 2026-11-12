import Foundation
import Synchronization
import Testing
@testable import WrappModuleKit

@Suite("Module protocol order")
nonisolated struct RPCOrderTests {
    @Test("What the other end says before its reply has all been heard, in order, when the request returns")
    func notificationsBeforeReply() async throws {
        // The program answers each request with its notifications and its
        // reply in one write, so they arrive together, as a program's last
        // `emit` and its step's reply can.
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
        answeringProgram(requests: toProgram.fileHandleForReading, replies: fromProgram.fileHandleForWriting, emits: count).start()

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
