//
//  VideoAnnotator.swift
//  WrappPuppeteer
//
//  A screen recording with what happened when written into it: a chapter at
//  each event, to jump to from a player's chapter menu, and a caption track
//  naming each event as it happens. The video itself is copied as it is, not
//  encoded again, so it costs a few seconds, and only for a failed launch.

import AVFoundation
import CoreMedia
import Foundation

public nonisolated enum VideoAnnotator {
    /// Something that happened, `time` seconds into the video.
    public struct Event: Sendable, Equatable {
        public let time: TimeInterval
        public let text: String

        public init(time: TimeInterval, text: String) {
            self.time = time
            self.text = text
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// How long a caption stays up, at most: the next event's replaces it.
    static let captionSeconds: TimeInterval = 3
    /// The caption track's height, at the foot of the picture.
    static let captionHeight: CGFloat = 120

    /// Copy `video` to `output` (a QuickTime movie, which keeps chapters),
    /// with `events` as chapters and captions.
    public static func annotate(_ video: URL, events: [Event], to output: URL) throws {
        let asset = AVURLAsset(url: video)
        let loaded = try load {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw Failure(description: "\(video.lastPathComponent) has no video")
            }
            return Loaded(track: track, duration: try await asset.load(.duration),
                          size: try await track.load(.naturalSize), format: try await track.load(.formatDescriptions).first)
        }
        let (track, duration, size) = (loaded.track, loaded.duration, loaded.size)

        let reader = try AVAssetReader(asset: asset)
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(source)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: loaded.format)
        let textFormat = try Self.textFormat()
        let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        chapterInput.marksOutputTrackAsEnabled = false
        let captionInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        captionInput.naturalSize = CGSize(width: size.width, height: captionHeight)
        captionInput.transform = CGAffineTransform(translationX: 0, y: size.height - captionHeight)
        // A player picks chapters and captions by language: the events are in English.
        for input in [chapterInput, captionInput] {
            input.languageCode = "eng"
            input.extendedLanguageTag = "en"
        }
        for input in [videoInput, chapterInput, captionInput] {
            guard writer.canAdd(input) else { throw Failure(description: "can't add a track to the annotated video") }
            writer.add(input)
        }
        videoInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)

        guard reader.startReading() else { throw Failure(description: "can't read \(video.lastPathComponent): \(reader.error.map { "\($0)" } ?? "")") }
        guard writer.startWriting() else { throw Failure(description: "can't write \(output.lastPathComponent): \(writer.error.map { "\($0)" } ?? "")") }
        writer.startSession(atSourceTime: .zero)

        let end = duration.seconds
        let chapters = try samples(chapters(events, end: end), format: textFormat)
        let captions = try samples(captions(events, end: end), format: textFormat)

        // Each track fed on its own queue as the writer asks, so it can
        // interleave them however it likes.
        let group = DispatchGroup()
        for feed in [Feed(input: videoInput) { source.copyNextSampleBuffer() },
                     Feed(input: chapterInput, samples: chapters), Feed(input: captionInput, samples: captions)] {
            group.enter()
            feed.start { group.leave() }
        }
        guard group.wait(timeout: .now() + 300) == .success else {
            writer.cancelWriting()
            throw Failure(description: "annotating \(video.lastPathComponent) took over 5 minutes")
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        if writer.status != .completed {
            throw Failure(description: "writing \(output.lastPathComponent) failed: \(writer.error.map { "\($0)" } ?? "")")
        }
    }

    /// The chapters: one from each event to the next, the first from the
    /// start, so every moment is in one.
    static func chapters(_ events: [Event], end: TimeInterval) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        let sorted = events.filter { $0.time < end }.sorted { $0.time < $1.time }
        var marks = sorted.map { (max($0.time, 0), $0.text) }
        if marks.first.map({ $0.0 > 0 }) ?? true { marks.insert((0, "Recording started"), at: 0) }
        return marks.enumerated().compactMap { index, mark in
            let next = index + 1 < marks.count ? marks[index + 1].0 : end
            return next > mark.0 ? (mark.0, next, mark.1) : nil
        }
    }

    /// The captions: each event's text for a few seconds or until the next,
    /// with empty text between, so the track runs the whole video.
    static func captions(_ events: [Event], end: TimeInterval) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        let sorted = events.filter { $0.time < end }.sorted { $0.time < $1.time }
        var cues: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        var cursor: TimeInterval = 0
        for (index, event) in sorted.enumerated() {
            let start = max(event.time, cursor)
            let next = index + 1 < sorted.count ? sorted[index + 1].time : end
            let stop = min(start + captionSeconds, max(next, start), end)
            // An event at the same moment as the next has no time of its own.
            guard stop > start else { continue }
            if start > cursor { cues.append((cursor, start, "")) }
            cues.append((start, stop, event.text))
            cursor = stop
        }
        if end > cursor { cues.append((cursor, end, "")) }
        return cues
    }

    /// 3GPP timed text: white on translucent black, centred, sans serif.
    static func textFormat() throws -> CMFormatDescription {
        func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int) -> [CFString: Int] {
            [kCMTextFormatDescriptionColor_Red: red, kCMTextFormatDescriptionColor_Green: green,
             kCMTextFormatDescriptionColor_Blue: blue, kCMTextFormatDescriptionColor_Alpha: alpha]
        }
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: color(0, 0, 0, 180),
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 48,
                kCMTextFormatDescriptionStyle_ForegroundColor: color(255, 255, 255, 255),
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: 1,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw Failure(description: "can't describe the text track (\(status))") }
        return format
    }

    /// A text sample for each span: its text, UTF-8 behind a 16-bit length.
    /// Each span's boundaries are rounded to the movie's timescale first, so
    /// one ends where the next starts, and one that rounds to nothing (an
    /// event a millisecond before the next) is left out.
    static func samples(_ spans: [(start: TimeInterval, end: TimeInterval, text: String)],
                        format: CMFormatDescription) throws -> [CMSampleBuffer] {
        let timescale: CMTimeScale = 600
        func ticks(_ seconds: TimeInterval) -> CMTimeValue { CMTimeValue((seconds * Double(timescale)).rounded()) }
        return try spans.compactMap { span -> CMSampleBuffer? in
            let (start, end) = (ticks(span.start), ticks(span.end))
            guard end > start else { return nil }
            let text = Data(span.text.utf8.prefix(Int(UInt16.max)))
            var bytes = Data([UInt8(text.count >> 8), UInt8(text.count & 0xFF)])
            bytes.append(text)
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
            guard status == noErr, let block else { throw Failure(description: "can't make a text sample (\(status))") }
            status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
            guard status == noErr else { throw Failure(description: "can't fill a text sample (\(status))") }
            var timing = CMSampleTimingInfo(duration: CMTime(value: end - start, timescale: timescale),
                                            presentationTimeStamp: CMTime(value: start, timescale: timescale),
                                            decodeTimeStamp: .invalid)
            var size = bytes.count
            var sample: CMSampleBuffer?
            status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                          makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1,
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard status == noErr, let sample else { throw Failure(description: "can't make a text sample (\(status))") }
            return sample
        }
    }

    /// An async AVFoundation property, waited for from synchronous code.
    private static func load<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let result = LockedResult<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.set(.success(try await body())) } catch { result.set(.failure(error)) }
            done.signal()
        }
        done.wait()
        return try result.get().get()
    }
}

/// What's loaded of the video, handed across from the task that loads it.
private nonisolated struct Loaded: @unchecked Sendable {
    let track: AVAssetTrack
    let duration: CMTime
    let size: CGSize
    let format: CMFormatDescription?
}

/// One track's samples, appended on a queue of its own whenever its input is
/// ready for more, until there are none.
private nonisolated final class Feed: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let next: () -> CMSampleBuffer?
    private let queue = DispatchQueue(label: "au.gare.callum.second-chance.WrappPuppeteer.VideoAnnotator.feed")

    init(input: AVAssetWriterInput, next: @escaping () -> CMSampleBuffer?) {
        self.input = input
        self.next = next
    }

    convenience init(input: AVAssetWriterInput, samples: [CMSampleBuffer]) {
        var remaining = samples[...]
        self.init(input: input) { remaining.popFirst() }
    }

    func start(done: @escaping @Sendable () -> Void) {
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                guard let sample = next() else {
                    input.markAsFinished()
                    done()
                    return
                }
                input.append(sample)
            }
        }
    }
}

private nonisolated final class LockedResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.withLock { self.value = value } }
    func get() throws -> Result<T, Error> {
        guard let value = lock.withLock({ self.value }) else { throw VideoAnnotator.Failure(description: "nothing loaded") }
        return value
    }
}
