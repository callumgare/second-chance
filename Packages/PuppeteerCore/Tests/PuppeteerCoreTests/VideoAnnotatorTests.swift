import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PuppeteerCore

/// A screen recording with its events written in: chapters to jump to and
/// captions naming each, the video itself copied as it is.
@Suite("Video annotation")
struct VideoAnnotatorTests {
    @Test("Chapters run from each event to the next, from the very start")
    func chapters() {
        let events = [VideoAnnotator.Event(time: 2, text: "Window"), .init(time: 0.5, text: "Started"), .init(time: 9, text: "After the end")]
        let chapters = VideoAnnotator.chapters(events, end: 5)
        #expect(chapters.map(\.text) == ["Recording started", "Started", "Window"])
        #expect(chapters.map(\.start) == [0, 0.5, 2])
        #expect(chapters.map(\.end) == [0.5, 2, 5])
    }

    @Test("Captions show each event for a few seconds or until the next, with blanks between")
    func captions() {
        let events = [VideoAnnotator.Event(time: 1, text: "A"), .init(time: 1.5, text: "B"), .init(time: 10, text: "C")]
        let captions = VideoAnnotator.captions(events, end: 12)
        #expect(captions.map(\.text) == ["", "A", "B", "", "C"])
        #expect(captions.map(\.start) == [0, 1, 1.5, 4.5, 10])
        #expect(captions.map(\.end) == [1, 1.5, 4.5, 10, 12])
    }

    @Test("Events at the same moment make no caption overlap another")
    func simultaneousEvents() {
        let events = [VideoAnnotator.Event(time: 4, text: "A"), .init(time: 4, text: "B"), .init(time: 5, text: "C")]
        let captions = VideoAnnotator.captions(events, end: 9)
        #expect(captions.map(\.text) == ["", "B", "C", ""])
        #expect(zip(captions, captions.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test("A recording comes back as a movie with its chapters and a caption track")
    func annotates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("screen.mp4")
        try Self.makeVideo(at: video, seconds: 3)
        let annotated = folder.appendingPathComponent("screen.mov")

        try VideoAnnotator.annotate(video, events: [.init(time: 1, text: "Game window appeared"), .init(time: 2, text: "Clicked Exit")],
                                    to: annotated)

        let asset = AVURLAsset(url: annotated)
        let titles = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: ["en"]).map { group in
            group.items.first { $0.commonKey == .commonKeyTitle }?.stringValue
        }
        #expect(titles == ["Recording started", "Game window appeared", "Clicked Exit"])
        #expect(asset.tracks(withMediaType: .text).count == 2)
        #expect(asset.tracks(withMediaType: .video).count == 1)
        #expect(abs(asset.duration.seconds - 3) < 0.2)
    }

    /// A small H.264 video of plain frames, 10 a second.
    static func makeVideo(at url: URL, seconds: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0...(seconds * 10) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 8 % 256), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }
}
