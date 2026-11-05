import Foundation
import Synchronization
import Testing
@testable import WrappModuleKit

@Suite("Module protocol cancels")
struct RPCCancelTests {
    @Test("A cancelled request the other end never answers is given up on, and its end told to go")
    func unansweredCancel() async throws {
        // The other end reads what it's sent and never replies.
        let toProgram = Pipe(), fromProgram = Pipe()
        let connection = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting,
                                       cancelGrace: .milliseconds(200))
        let ended = Mutex(false)
        connection.whenCancelUnanswered { ended.withLock { $0 = true } }
        let request = Task { try await connection.request("run", Nothing(), as: Nothing?.self) }
        // Cancelled whether or not it's been sent yet: either way it's given up on.
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(ended.withLock { $0 })
        connection.close()
    }
}
