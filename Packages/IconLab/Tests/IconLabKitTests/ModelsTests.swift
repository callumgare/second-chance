import CoreML
import Foundation
import Testing
@testable import IconLabKit

/// The tokenizer's vocabulary is downloaded like a model (data/models/clip-tokenizer); these run once it's there.
/// Expected ids are from Hugging Face's own `tokenizers` (Rust) with openai/clip-vit-base-patch32's tokenizer.json.
nonisolated enum TokenizerFiles {
    static let dir = TestData.dir.appendingPathComponent("models/clip-tokenizer")
    static let present = FileManager.default.fileExists(atPath: dir.appendingPathComponent("merges.txt").path)
}

@Suite(.enabled(if: TokenizerFiles.present, "needs data/models/clip-tokenizer (POST /api/models/clip-tokenizer/download)"))
struct CLIPTokenizerTests {
    let tokenizer: CLIPTokenizer
    init() throws { tokenizer = try CLIPTokenizer(folder: TokenizerFiles.dir) }

    @Test(arguments: [
        ("a photo of a cat", [320, 1125, 539, 320, 2368]),
        ("the front cover of a software box", [518, 2184, 2202, 539, 320, 5847, 2063]),
        ("a CD-ROM disc", [320, 4480, 268, 19205, 10712]),
        ("a compact disc label", [320, 13690, 10712, 9093]),
        ("a small pixel art program icon", [320, 2442, 13241, 794, 2737, 5646]),
        ("Zoombinis' Logical Journey!!", [32671, 4849, 533, 262, 4791, 3749, 748]),
        ("don't stop 1995, it's 3.11 WINDOWS", [847, 713, 1691, 272, 280, 280, 276, 267, 585, 568, 274, 269, 272, 272, 5437]),
        ("  multiple   spaces\there ", [6470, 9006, 763]),
    ] as [(String, [Int32])])
    func knownIds(_ text: String, _ ids: [Int32]) {
        #expect(tokenizer.encode(text) == ids)
    }

    @Test func wrapsAndPads() {
        let t = tokenizer.tokenize("a photo of a cat")
        #expect(t.count == 77)
        #expect(Array(t.prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407])
        #expect(t.dropFirst(7).allSatisfy { $0 == 0 })
        let long = tokenizer.tokenize(String(repeating: "cat ", count: 200))
        #expect(long.count == 77 && long[76] == 49407)
    }
}

struct ModelsPureTests {
    @Test func manifestIsWhole() {
        for s in ModelManifest.all {
            #expect(!s.files.isEmpty)
            for f in s.files {
                #expect(f.sha256.count == 64)
                #expect(f.url.hasPrefix("https://huggingface.co/"))
                #expect(f.url.contains("/resolve/") && !f.url.contains("/resolve/main/"), "pinned to a commit")
            }
        }
        #expect(ModelManifest.spec(Models.clipImage) != nil && ModelManifest.spec(Models.upscaler) != nil)
    }

    @Test func tilesRepeatTheirEdges() {
        var b = Bitmap(width: 2, height: 2)
        b.pixels = [10, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255, 40, 0, 0, 255]
        let t = Models.tileClamped(b, x: -1, y: -1, size: 4)
        #expect(t.pixels[t.index(0, 0)] == 10)
        #expect(t.pixels[t.index(3, 0)] == 20)
        #expect(t.pixels[t.index(0, 3)] == 30)
        #expect(t.pixels[t.index(3, 3)] == 40)
    }

    @Test func downloadChecksItsChecksum() async throws {
        // a file served from disk: right checksum lands, wrong one throws and leaves nothing
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.bin")
        try Data("hello models".utf8).write(to: src)
        let sha = try ModelStore.sha256(of: src)
        let dest = dir.appendingPathComponent("out.bin")
        try await FileDownload.fetch(src, to: dest, size: 12, sha256: sha) { _ in }
        #expect(try Data(contentsOf: dest) == Data("hello models".utf8))
        let bad = dir.appendingPathComponent("bad.bin")
        await #expect(throws: (any Error).self) {
            try await FileDownload.fetch(src, to: bad, size: 12, sha256: String(repeating: "0", count: 64)) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: bad.path) && !FileManager.default.fileExists(atPath: bad.path + ".part"))
    }
}

struct SegmenterTests {
    @Test func pointsScaleToTheStretchedInput() {
        let p = Segmenter.prompt(points: [.init(x: 0.25, y: 0.5, positive: true), .init(x: 1, y: 0, positive: false)], region: nil)
        #expect(p.count == 2)
        #expect(p[0].x == 256 && p[0].y == 512 && p[0].label == 1)
        #expect(p[1].x == 1024 && p[1].y == 0 && p[1].label == 0)
    }

    @Test func regionIsTwoCornersFirst() {
        let p = Segmenter.prompt(points: [.init(x: 0.5, y: 0.5, positive: true)], region: [0.1, 0.2, 0.5, 0.25])
        #expect(p.map(\.label) == [2, 3, 1])
        #expect(abs(p[0].x - 102.4) < 0.01 && abs(p[0].y - 204.8) < 0.01)
        #expect(abs(p[1].x - 614.4) < 0.01 && abs(p[1].y - 460.8) < 0.01)
    }

    @Test func outsideThePictureIsClamped() {
        let p = Segmenter.prompt(points: [.init(x: -0.2, y: 1.3, positive: true)], region: nil)
        #expect(p[0].x == 0 && p[0].y == 1024)
    }

    @Test func encodingSurvivesTheDisk() throws {
        let parts = [SAMEncoding.Part(shape: [1, 2, 2], type: Int(MLMultiArrayDataType.float16.rawValue), bytes: Data([1, 2, 3, 4, 5, 6, 7, 8])),
                     SAMEncoding.Part(shape: [1, 1], type: Int(MLMultiArrayDataType.float16.rawValue), bytes: Data([9, 10])),
                     SAMEncoding.Part(shape: [2], type: Int(MLMultiArrayDataType.float16.rawValue), bytes: Data([11, 12, 13, 14]))]
        let back = try #require(SAMEncoding(SAMEncoding(parts: parts).encoded()))
        #expect(back.parts.map(\.shape) == [[1, 2, 2], [1, 1], [2]])
        #expect(back.parts.map(\.bytes) == parts.map(\.bytes))
        #expect(SAMEncoding(Data("nope".utf8)) == nil)
    }

    @Test func maskEdgeIsTheZeroContour() throws {
        // logits −4 … +4 across 2 pixels, upsampled to 9: the middle is 0, so grey ≈ 128 there
        let up = Segmenter.upsample([-4, 4, -4, 4], width: 2, height: 2, toWidth: 9, toHeight: 1)
        let b = Segmenter.maskBitmap(up, width: 9, height: 1)
        #expect(b.pixels[0] == 0 && b.pixels[8 * 4] == 255)
        #expect(try #require(up.first) < (try #require(up.last)))
    }
}
