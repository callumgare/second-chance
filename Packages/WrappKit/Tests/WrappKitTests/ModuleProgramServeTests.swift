import Foundation
import Testing
@testable import WrappModuleKit

@Suite("A connection's handler and its first message")
nonisolated struct ModuleProgramServeTests {
    /// The build sends `hello` the moment it starts a module's program, so
    /// on a slow Mac the request is waiting before the program's connection
    /// exists. A handler set after the connection started reading could
    /// miss it, and `hello` was answered "nothing answers hello" (a CI
    /// runner, once in a few runs). `makeHandler`'s is in place before
    /// anything is read, however long it takes to make.
    @Test("A request waiting before the connection is answered, however long its handler takes to make")
    func requestAlreadyWaiting() async throws {
        let toProgram = Pipe(), fromProgram = Pipe()
        let build = RPCConnection(input: fromProgram.fileHandleForReading, output: toProgram.fileHandleForWriting)
        let reply = Task { try await build.request("hello", Hello(protocol: ModuleProtocol.version), as: Hello.self) }
        let fd = toProgram.fileHandleForReading.fileDescriptor
        let waiting = await Task.detached { () -> Bool in
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return poll(&request, 1, 10_000) == 1
        }.value
        try #require(waiting, "the request reached the program's pipe")

        let program = RPCConnection(input: toProgram.fileHandleForReading, output: fromProgram.fileHandleForWriting) { _ in
            // A slow start: a handler set after reading began would miss the request by now.
            Thread.sleep(forTimeInterval: 0.2)
            return { method, _ in
                guard method == "hello" else { return nil }
                return try JSONEncoder().encode(Hello(protocol: ModuleProtocol.version, handles: ["IDLE"]))
            }
        }
        let hello = try await reply.value
        #expect(hello.handles == ["IDLE"])
        build.close()
        program.close()
    }
}
