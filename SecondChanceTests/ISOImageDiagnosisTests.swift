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
        let diagnosis = ISOMounter.diagnoseImage(at: url)
        #expect(diagnosis.problem == .incomplete)
        #expect(diagnosis.description.hasPrefix("it is truncated"))
    }

    @Test("A file without an ISO 9660 header isn't a CD image")
    func notAnImage() throws {
        let url = try write(Data(repeating: 0x5A, count: 50_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let diagnosis = ISOMounter.diagnoseImage(at: url)
        #expect(diagnosis.problem == .notADiscImage)
        #expect(diagnosis.description.contains("no ISO 9660 header"))
    }

    @Test("A raw CD image (a BIN) is told from a file that isn't one")
    func rawImage() throws {
        // Each 2352-byte sector starts with the 12-byte sync pattern.
        var sector = Data([0x00] + Array(repeating: 0xFF, count: 10) + [0x00])
        sector.append(Data(count: 2352 - sector.count))
        let url = try write(Data((0..<20).flatMap { _ in sector }))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ISOMounter.diagnoseImage(at: url).problem == .rawCDImage)
    }

    @Test("A complete image is described as one")
    func complete() throws {
        let url = try write(isoHeader(blocks: 20, length: 20 * 2048))
        defer { try? FileManager.default.removeItem(at: url) }
        let diagnosis = ISOMounter.diagnoseImage(at: url)
        #expect(diagnosis.problem == .wontOpen)
        #expect(diagnosis.description.contains("ISO 9660 image"))
    }
}
