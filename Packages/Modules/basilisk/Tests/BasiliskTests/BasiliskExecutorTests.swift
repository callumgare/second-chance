@testable import BasiliskExecutor
import Foundation
import Testing

struct BasiliskExecutorTests {
    @Test("A disc image is told from another by its size and first megabyte")
    func fingerprints() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basilisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("one.iso"), two = folder.appendingPathComponent("two.iso")
        try Data(repeating: 1, count: 4096).write(to: one)
        try Data(repeating: 2, count: 4096).write(to: two)
        #expect(try BasiliskExecutor.fingerprint(one) != BasiliskExecutor.fingerprint(two))
        #expect(try BasiliskExecutor.fingerprint(one).hasPrefix("4096-"))
    }
}
