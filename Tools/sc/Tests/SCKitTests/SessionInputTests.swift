import ArgumentParser
import Foundation
import Testing
@testable import SCKit

struct SessionInputTests {
    @Test("Clicks, moves and drags read their points, and a button and count")
    func pointer() throws {
        #expect(try SessionInput.parse(["click", "920", "594"], button: nil, count: 1) == .click(x: 920, y: 594, buttons: 1, count: 1))
        #expect(try SessionInput.parse(["click", "1", "2"], button: "right", count: 2) == .click(x: 1, y: 2, buttons: 4, count: 2))
        #expect(try SessionInput.parse(["move", "3.5", "4"], button: nil, count: 1) == .move(x: 3.5, y: 4))
        #expect(try SessionInput.parse(["drag", "1", "2", "3", "4"], button: nil, count: 1) == .drag(x: 1, y: 2, toX: 3, toY: 4))
        #expect(throws: ValidationError.self) { try SessionInput.parse(["click", "920"], button: nil, count: 1) }
        #expect(throws: ValidationError.self) { try SessionInput.parse(["click", "1", "2"], button: "side", count: 1) }
        #expect(throws: ValidationError.self) { try SessionInput.parse(["wave"], button: nil, count: 1) }
    }

    @Test("Keys are names, characters, chords and repeats, as X11 keysyms")
    func keys() throws {
        #expect(try SessionInput.parse(["key", "return"], button: nil, count: 1) == .keys([[0xFF0D]]))
        #expect(try SessionInput.parse(["key", "cmd+q", "down*2"], button: nil, count: 1)
                == .keys([[0xFFE7, 0x71], [0xFF54], [0xFF54]]))
        #expect(try SessionInput.parse(["key", "F5"], button: nil, count: 1) == .keys([[0xFFC2]]))
        #expect(throws: ValidationError.self) { try SessionInput.parse(["key", "hyper"], button: nil, count: 1) }
    }

    @Test("Text is typed as Latin-1 keysyms, anything else as Unicode ones")
    func text() throws {
        #expect(try SessionInput.parse(["type", "hi", "there"], button: nil, count: 1) == .type("hi there"))
        #expect(SessionInput.character("é") == 0xE9)
        #expect(SessionInput.character("→") == 0x0100_2192)
    }

    @Test("A --then action splits at spaces outside quotes")
    func words() {
        #expect(SessionInput.words(#"type "a b"  key return"#) == ["type", "a b", "key", "return"])
    }
}

/// The keep-alive's socket, talked to as `sc session do` does, through nc.
@Suite(.serialized)
struct SessionInputServerTests {
    /// `requests` sent as JSON lines and an empty line, the replies read back.
    static func send(_ requests: [SessionInputRequest], to path: String) async throws -> [SessionInputReply] {
        let encoder = JSONEncoder()
        var input = Data()
        for request in requests { input += try encoder.encode(request) + Data("\n".utf8) }
        input += Data("\n".utf8)
        let output = try await Task.detached { () throws -> Data in
            let nc = Process()
            nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            nc.arguments = ["-U", path]
            let stdin = Pipe(), stdout = Pipe()
            nc.standardInput = stdin
            nc.standardOutput = stdout
            try nc.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            nc.waitUntilExit()
            return data
        }.value
        return try output.split(separator: UInt8(ascii: "\n")).map { try JSONDecoder().decode(SessionInputReply.self, from: Data($0)) }
    }

    static func folder() throws -> URL {
        // A socket's path must be short, so not the long temporary directory.
        let folder = URL(fileURLWithPath: "/tmp/sc-input-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("Without a connection, a request is turned away at once")
    func unconnected() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try SessionInputServer(user: NSUserName(), folder: folder)
        defer { server.close() }
        let replies = try await Self.send([SessionInputRequest(input: .move(x: 1, y: 2), width: nil)],
                                          to: SessionInputServer.socketPath(for: NSUserName(), in: folder))
        #expect(replies.count == 1)
        #expect(replies.first?.error?.contains("isn't connected") == true)
    }

    @Test("Each request reaches the keep-alive in turn and is answered once it's done")
    func answered() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try SessionInputServer(user: NSUserName(), folder: folder)
        defer { server.close() }
        server.setConnected(true)
        let sent = [SessionInputRequest(input: .click(x: 920, y: 594, buttons: 1, count: 1), width: 1600),
                    SessionInputRequest(input: .type("hi"), width: nil)]
        let client = Task { try await Self.send(sent, to: SessionInputServer.socketPath(for: NSUserName(), in: folder)) }
        let first = try #require(await server.next(within: 10))
        #expect(first.request == sent[0])
        first.finish()
        let second = try #require(await server.next(within: 10))
        #expect(second.request == sent[1])
        second.finish(error: "no keyboard")
        let replies = try await client.value
        #expect(replies == [SessionInputReply(error: nil), SessionInputReply(error: "no keyboard")])
    }
}
