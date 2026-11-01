import Foundation
import Logging
import Synchronization
import Testing
@testable import SecondChanceKit

/// How a subprocess's output is split into lines: across reads, at either
/// kind of line ending, and with a limit on a line that never ends.
@Suite("Process line logger")
struct ProcessLineLoggerTests {
    /// The lines `chunks`, written to a pipe one write each, come out as.
    private func lines(of chunks: [Data]) async -> [String] {
        let pipe = Pipe()
        let seen = Mutex<[String]>([])
        let finished = DispatchSemaphore(value: 0)
        ProcessLineLogger.attach(
            to: pipe, logger: Logger(label: "au.gare.callum.second-chance.Test.Lines"), level: .debug,
            onLine: { line in seen.withLock { $0.append(line) } },
            onEOF: { finished.signal() }
        )
        for chunk in chunks {
            pipe.fileHandleForWriting.write(chunk)
        }
        try? pipe.fileHandleForWriting.close()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = finished.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
        return seen.withLock { $0 }
    }

    @Test("Lines split across reads come out whole, and the last one without a newline too")
    func splitAcrossReads() async {
        let lines = await lines(of: [Data("first li".utf8), Data("ne\nsecond\nthi".utf8), Data("rd".utf8)])
        #expect(lines == ["first line", "second", "third"])
    }

    @Test("Carriage returns end lines, and CRLF makes no empty ones")
    func carriageReturns() async {
        let lines = await lines(of: [Data("one\r\ntwo\rthree\n".utf8)])
        #expect(lines == ["one", "two", "three"])
    }

    @Test("A line that never ends is let out in pieces")
    func endlessLine() async {
        let long = Data(repeating: UInt8(ascii: "x"), count: ProcessLineLogger.maxLineBytes + 10)
        let lines = await lines(of: [long])
        #expect(lines.count >= 1)
        #expect(lines.allSatisfy { $0.utf8.count <= ProcessLineLogger.maxLineBytes + 10 })
        #expect(lines.joined().utf8.count == long.count)
    }
}
