import Testing
import Foundation
@testable import SecondChance

@Suite("ISO image diagnosis")
struct ISOImageDiagnosisTests {

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString).iso")
        try data.write(to: url)
        return url
    }

    /// A header for an image of `blocks` 2048-byte blocks, cut to `length` bytes.
    private func isoHeader(blocks: UInt32, length: Int) -> Data {
        var data = Data(count: max(length, 16 * 2048 + 2048))
        let pvd = 16 * 2048
        data[pvd] = 1
        data.replaceSubrange((pvd + 1)..<(pvd + 6), with: Array("CD001".utf8))
        withUnsafeBytes(of: blocks.littleEndian) { data.replaceSubrange((pvd + 80)..<(pvd + 84), with: $0) }
        withUnsafeBytes(of: UInt16(2048).littleEndian) { data.replaceSubrange((pvd + 128)..<(pvd + 130), with: $0) }
        return data.prefix(length)
    }

    @Test("A truncated image says how much of it is there")
    func truncated() throws {
        let url = try write(isoHeader(blocks: 1_000, length: 100 * 2048))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ISOMounter.diagnoseImage(at: url).hasPrefix("it is truncated"))
    }

    @Test("A file without an ISO 9660 header isn't a CD image")
    func notAnImage() throws {
        let url = try write(Data(repeating: 0x5A, count: 50_000))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ISOMounter.diagnoseImage(at: url).contains("no ISO 9660 header"))
    }

    @Test("A complete image is described as one")
    func complete() throws {
        let url = try write(isoHeader(blocks: 20, length: 20 * 2048))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ISOMounter.diagnoseImage(at: url).contains("ISO 9660 image"))
    }
}
