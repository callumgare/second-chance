import AVFoundation
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO

// What `sc puppet record`, `sheet` and `audio` need beyond the picture a
// `shot` takes. See docs/dev-cli.md#puppet-sessions.

// MARK: Actions

/// Dates in ISO 8601 with milliseconds: an action and the frame it changed
/// are often under a second apart.
enum PreciseDates {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }
}

/// One `do` action, kept so a recording can mark it as a chapter and a
/// contact sheet can say what came before a frame.
struct PuppetAction: Codable, Equatable {
    var time: Date
    var action: String
}

extension PuppetSession {
    /// Every `do` since the session started, a line of JSON each.
    var actionsFile: URL { folder.appendingPathComponent("actions.jsonl") }
    var recordings: URL { folder.appendingPathComponent("recordings") }

    /// Notes an action as it's sent to the game.
    func noteAction(_ action: String, at time: Date = Date()) {
        guard var line = try? PreciseDates.encoder().encode(PuppetAction(time: time, action: action)) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: actionsFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: actionsFile)
        }
    }

    func actions(from start: Date, to end: Date) -> [PuppetAction] {
        PuppetAction.parse((try? String(contentsOf: actionsFile, encoding: .utf8)) ?? "")
            .filter { $0.time >= start && $0.time <= end }
    }
}

extension PuppetAction {
    static func parse(_ text: String) -> [PuppetAction] {
        let decoder = PreciseDates.decoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(PuppetAction.self, from: Data($0.utf8)) }
    }
}

// MARK: Recording

/// A recording's facts, kept beside its movie (`<movie>.json`) so a contact
/// sheet knows what time each frame was.
struct PuppetRecording: Codable {
    var movie: String
    var started: Date
    var ended: Date
    var frames: Int
    var width: Int
    var height: Int
    var actions: [PuppetAction]

    var sidecar: URL { URL(fileURLWithPath: movie + ".json") }

    func save() throws {
        let encoder = PreciseDates.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: sidecar, options: .atomic)
    }

    /// The session's recordings, oldest first.
    static func all(in folder: URL) -> [PuppetRecording] {
        let decoder = PreciseDates.decoder()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".mov.json") }
            .compactMap { try? decoder.decode(PuppetRecording.self, from: Data(contentsOf: folder.appendingPathComponent($0))) }
            .sorted { $0.started < $1.started }
    }
}

enum PuppetMovie {
    /// The scale, in pixels a point, that fits a window's long edge in
    /// `longEdge` pixels, never above the window's own (asked for more, an
    /// OpenGL game's surface comes back small in a corner).
    static func scale(window: (width: Double, height: Double, scale: Double), longEdge: Double) -> Double {
        min(longEdge / max(window.width, window.height, 1), window.scale)
    }

    /// Chapters for the actions in a recording: one from the start, then one
    /// at each action, each lasting until the next. Seconds from the start.
    static func chapters(_ actions: [PuppetAction], started: Date, duration: Double) -> [(start: Double, end: Double, title: String)] {
        var marks: [(Double, String)] = actions.map { (max(0, $0.time.timeIntervalSince(started)), $0.action) }
            .filter { $0.0 < duration }
            .sorted { $0.0 < $1.0 }
        if marks.first.map({ $0.0 > 0.05 }) ?? true { marks.insert((0, "start"), at: 0) }
        return marks.enumerated().map { index, mark in
            (mark.0, index + 1 < marks.count ? marks[index + 1].0 : duration, mark.1)
        }.filter { $0.end > $0.start }
    }

    /// The frames, PNGs taken at the times given (seconds from the start),
    /// into an H.264 QuickTime movie, with a chapter track when there are
    /// chapters. Returns the movie's size.
    static func write(to url: URL, frames: [(time: Double, file: URL)], chapters: [(start: Double, end: Double, title: String)],
                      duration: Double) async throws -> (width: Int, height: Int) {
        guard let first = frames.first, let firstImage = Frames.image(at: first.file) else { throw SCError("No frames to write.") }
        let width = firstImage.width / 2 * 2, height = firstImage.height / 2 * 2
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)

        let timescale: CMTimeScale = 600
        // Chapters are a QuickTime text track the video names as its chapter
        // list: what QuickTime Player and AVFoundation read them from (a
        // timed-metadata track is written but its titles aren't read).
        let samples = chapters.compactMap { textSample($0.title, start: $0.start, end: $0.end, timescale: timescale) }
        var chapterInput: AVAssetWriterInput?
        if let hint = samples.first.flatMap(CMSampleBufferGetFormatDescription) {
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            writer.add(input)
            video.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            chapterInput = input
        }

        guard writer.startWriting() else { throw SCError("Couldn't start the movie: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        var frameIndex = 0, chapterIndex = 0, lastTime = CMTime.negativeInfinity
        if chapterInput == nil { chapterIndex = samples.count }
        // Each input fed as it's ready, so neither waits on the other to
        // catch up.
        while frameIndex < frames.count || chapterIndex < samples.count {
            var progressed = false
            if chapterIndex < samples.count, let chapterInput, chapterInput.isReadyForMoreMediaData {
                chapterInput.append(samples[chapterIndex])
                chapterIndex += 1
                if chapterIndex == samples.count { chapterInput.markAsFinished() }
                progressed = true
            }
            if frameIndex < frames.count, video.isReadyForMoreMediaData {
                let frame = frames[frameIndex]
                frameIndex += 1
                // The first from the start: a gap before it reads back as a
                // black frame.
                let time = frameIndex == 1 ? .zero : CMTime(seconds: frame.time, preferredTimescale: timescale)
                if time > lastTime, let image = Frames.image(at: frame.file), let pool = adaptor.pixelBufferPool,
                   let buffer = pixelBuffer(image, pool: pool) {
                    adaptor.append(buffer, withPresentationTime: time)
                    lastTime = time
                }
                if frameIndex == frames.count { video.markAsFinished() }
                progressed = true
            }
            if writer.status == .failed { break }
            if !progressed { try await Task.sleep(for: .milliseconds(5)) }
        }
        if frames.isEmpty { video.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(seconds: max(duration, lastTime.seconds), preferredTimescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SCError("Couldn't write \(url.lastPathComponent): \(writer.error.map { String(describing: $0) } ?? "?")")
        }
        return (width, height)
    }

    /// A QuickTime text sample: the text's length (16 bits, big-endian), the
    /// text, and an `encd` atom saying it's UTF-8.
    static func textSample(_ text: String, start: Double, end: Double, timescale: CMTimeScale) -> CMSampleBuffer? {
        // QuickTime text's format. It has to say the style's height and
        // ascent, or the movie won't take it ("format description is invalid").
        let white: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                                      kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255]
        let black: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                                      kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_TextJustification: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: black,
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 12, kCMTextFormatDescriptionStyle_Height: 12,
                kCMTextFormatDescriptionStyle_Ascent: 9, kCMTextFormatDescriptionStyle_ForegroundColor: white,
            ],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
            kCMTextFormatDescriptionExtension_DefaultFontName: "Sans-Serif",
        ]
        var format: CMFormatDescription?
        guard CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_QTText,
                                        extensions: extensions as CFDictionary, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        let utf8 = Array(text.utf8.prefix(Int(UInt16.max) - 16))
        var bytes: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
        bytes += [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: end - start, preferredTimescale: timescale),
                                        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: timescale),
                                        decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// `image` drawn into a buffer from `pool`, scaled to fill it.
    static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Every frame of a movie, with its time in seconds from the start.
    static func frames(of url: URL, each: (Double, CGImage) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SCError("\(url.lastPathComponent) has no video.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw SCError("Couldn't read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "?")") }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                                    height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            let image = context?.makeImage()
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            if let image { each(CMSampleBufferGetPresentationTimeStamp(sample).seconds, image) }
        }
    }

    /// The chapter titles a movie carries, with their start in seconds.
    static func chapterTitles(of url: URL) async throws -> [(start: Double, title: String)] {
        let asset = AVURLAsset(url: url)
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? Locale(identifier: "und"),
                                                               containingItemsWithCommonKeys: [.commonKeyTitle])
        var titles: [(Double, String)] = []
        for group in groups {
            let title = try await group.items.first?.load(.stringValue) ?? ""
            titles.append((group.timeRange.start.seconds, title))
        }
        return titles
    }
}

// MARK: Contact sheet

enum PuppetSheet {
    struct Tile {
        var time: Date
        var image: CGImage
        /// Actions since the tile before.
        var after: [String]
    }

    /// Whether a frame is worth a tile: the first, or one that differs
    /// from the last tile by more than `threshold` % of the change thumbnail.
    static func shows(_ thumbnail: [UInt8], after last: [UInt8]?, threshold: Int) -> Bool {
        guard let last else { return true }
        return Frames.changed(last, thumbnail) > threshold
    }

    /// At most `count` of `items`, evenly spread, the first and last kept.
    static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 1 else { return Array(items.prefix(max(count, 0))) }
        return (0..<count).map { items[Int((Double($0) * Double(items.count - 1) / Double(count - 1)).rounded())] }
    }

    /// `--since`: a time of day (HH:MM or HH:MM:SS, today) or a while ago
    /// (90s, 2m).
    static func since(_ text: String, now: Date = Date()) -> Date? {
        let parts = text.split(separator: ":").map { Int($0) }
        if parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0 != nil }) {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
            components.hour = parts[0]
            components.minute = parts[1]
            components.second = parts.count == 3 ? parts[2] : 0
            return Calendar.current.date(from: components)
        }
        return ScreenLease.parseDuration(text.hasSuffix("s") || text.hasSuffix("m") || text.hasSuffix("h") ? text : text + "s")
            .map { now.addingTimeInterval(-$0) }
    }

    static func clock(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm:ss.S"
        return format.string(from: date)
    }

    /// The tiles in a grid, each `tileWidth` across with its time (and the
    /// actions before it) above.
    static func draw(_ tiles: [Tile], columns: Int, tileWidth: Int, started: Date) -> CGImage? {
        guard let first = tiles.first else { return nil }
        let columns = max(1, min(columns, tiles.count))
        let rows = (tiles.count + columns - 1) / columns
        let tileHeight = Int((Double(tileWidth) * Double(first.image.height) / Double(max(first.image.width, 1))).rounded())
        let label = 34, gap = 6
        let width = columns * tileWidth + (columns + 1) * gap
        let height = rows * (tileHeight + label) + (rows + 1) * gap
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        func text(_ string: String, at point: CGPoint, grey: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: grey, alpha: 1),
            ]
            var shown = string
            while shown.count > 4, Double(shown.count) * 7.3 > Double(tileWidth) { shown = String(shown.dropLast(2)) + "…" }
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: shown, attributes: attributes)), context)
        }
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + column * (tileWidth + gap)
            // CoreGraphics counts from the bottom.
            let top = height - gap - row * (tileHeight + label + gap)
            let offset = String(format: "+%.1fs", tile.time.timeIntervalSince(started))
            text("\(index + 1). \(clock(tile.time)) \(offset)", at: CGPoint(x: x + 2, y: top - 14), grey: 0.95)
            if !tile.after.isEmpty {
                text("after " + tile.after.joined(separator: "; "), at: CGPoint(x: x + 2, y: top - 29), grey: 0.7)
            }
            context.draw(tile.image, in: CGRect(x: x, y: top - label - tileHeight, width: tileWidth, height: tileHeight))
        }
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw SCError("Couldn't write \(url.path).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SCError("Couldn't write \(url.path).") }
    }
}

// MARK: Audio

/// Sound levels from `sc-audio-tap`, and what they add up to.
struct AudioLevel: Equatable {
    var time: Double
    var peak: Double
    var rms: Double

    /// A `level t= peak= rms=` line.
    init?(line: String) {
        guard line.hasPrefix("level ") else { return nil }
        let fields = Dictionary(line.split(separator: " ").dropFirst().compactMap { word -> (String, Double)? in
            let parts = word.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }, uniquingKeysWith: { first, _ in first })
        guard let time = fields["t"], let peak = fields["peak"], let rms = fields["rms"] else { return nil }
        self.init(time: time, peak: peak, rms: rms)
    }

    init(time: Double, peak: Double, rms: Double) {
        self.time = time
        self.peak = peak
        self.rms = rms
    }

    /// Below this a window is silence: -60 dBFS.
    static let silence = 0.001
    /// At or above this a sample is at full scale.
    static let fullScale = 0.999

    static func decibels(_ value: Double) -> String {
        value <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(value))
    }

    /// One line: silent, sound or clipping.
    static func summary(_ levels: [AudioLevel]) -> String {
        guard !levels.isEmpty else { return "no samples: the tap gave nothing" }
        let sounding = levels.filter { $0.peak >= silence }
        let clipped = levels.filter { $0.peak >= fullScale }
        let peak = levels.map(\.peak).max() ?? 0, rms = levels.map(\.rms).max() ?? 0
        let loudest = "peak \(decibels(peak)) dBFS, RMS up to \(decibels(rms)) dBFS"
        if sounding.isEmpty { return "silent: every window under -60 dBFS (\(loudest))" }
        if !clipped.isEmpty { return "clipping: \(clipped.count) of \(levels.count) windows reach full scale; sound in \(sounding.count) (\(loudest))" }
        return "sound in \(sounding.count) of \(levels.count) windows (\(loudest))"
    }

    /// A row a second: its windows' RMS as bars (· for silence), and its
    /// loudest peak and RMS.
    static func rows(_ levels: [AudioLevel], perRow: Int = 10) -> [String] {
        let bars = Array("▁▂▃▄▅▆▇█")
        return stride(from: 0, to: levels.count, by: perRow).map { start in
            let row = levels[start..<min(start + perRow, levels.count)]
            let picture = String(row.map { level -> Character in
                guard level.peak >= silence, level.rms > 0 else { return "·" }
                let db = max(-60, min(0, 20 * log10(level.rms)))
                return bars[min(bars.count - 1, Int((db + 60) / 60 * Double(bars.count)))]
            })
            let padded = picture.padding(toLength: perRow, withPad: " ", startingAt: 0)
            let from = String(format: "%5.1fs", (row.first?.time ?? 0) - 0.1)
            return "\(from)  \(padded)  peak \(decibels(row.map(\.peak).max() ?? 0)), rms \(decibels(row.map(\.rms).max() ?? 0))"
        }
    }
}

/// The pids under `root` in a `ps -axo pid=,ppid=` listing, `root` first.
enum ProcessTree {
    static func parse(_ listing: String) -> [(pid: pid_t, parent: pid_t)] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return (pid, parent)
        }
    }

    static func descendants(of root: pid_t, in processes: [(pid: pid_t, parent: pid_t)]) -> [pid_t] {
        var found = [root], index = 0
        while index < found.count {
            let parent = found[index]
            found += processes.filter { $0.parent == parent && !found.contains($0.pid) }.map(\.pid)
            index += 1
        }
        return found
    }
}

/// `sc-audio-tap`, built from `Tools/sc/AudioTap/main.swift` into an app of
/// its own, which is what macOS gives the system-audio permission to.
enum AudioTapApp {
    static let identifier = "au.gare.callum.second-chance.sc-audio-tap"
    static let name = "SC Audio Tap"
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SecondChance/sc-audio-tap")
    }
    static var app: URL { folder.appendingPathComponent("\(name).app") }
    static var executable: URL { app.appendingPathComponent("Contents/MacOS/sc-audio-tap") }
    static var stampFile: URL { folder.appendingPathComponent("stamp") }

    static func infoPlist() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleExecutable": "sc-audio-tap",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": true,
            "LSMinimumSystemVersion": "14.2",
            "NSAudioCaptureUsageDescription": "sc puppet audio measures how loud the program it drives is, to tell sound from silence.",
        ], format: .xml, options: 0)
    }

    /// The helper, built and signed unless what it's built from and signed
    /// with is as before: a new signature can lose its permission. Signed
    /// with the developer's identity when this user has one (the permission
    /// then outlasts a rebuild), otherwise ad hoc. Returns how it's signed.
    static func ensure(repo: URL, ui: UI) async throws -> String {
        let source = repo.appendingPathComponent("Tools/sc/AudioTap/main.swift")
        guard let code = try? Data(contentsOf: source) else {
            // A runtime copy has no sources: it brings the tap built and
            // signed on the Mac that sent it (`stage`).
            return try await installShipped(from: repo.appendingPathComponent(shippedPath))
        }
        let plist = try infoPlist()
        let identity = SigningIdentity.development().first
        let signer = identity.map { "\($0.name) (\($0.hash))" } ?? "ad hoc"
        let stamp = SHA256.hash(data: code + plist + Data(signer.utf8)).map { String(format: "%02x", $0) }.joined()
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp, FileManager.default.isExecutableFile(atPath: executable.path) {
            return signer
        }
        return try await ui.progressStep("Building \(name)", success: "Built \(name), signed \(signer)") { _ in
            try? FileManager.default.removeItem(at: app)
            let macOS = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            let built = try await Proc.collect("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-O", source.path, "-o", executable.path])
            guard built.succeeded else { throw SCError("Couldn't build \(name):\n\(built.error)") }
            var signed = identity.map(\.hash)
            if let hash = signed {
                let result = try await Proc.collect("/usr/bin/codesign", ["--force", "--sign", hash, "--identifier", identifier, app.path])
                if !result.succeeded {
                    ui.detail("Couldn't sign with \(signer) (\(result.error.trimmingCharacters(in: .whitespacesAndNewlines))); signing ad hoc.")
                    signed = nil
                }
            }
            if signed == nil {
                let result = try await Proc.collect("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path])
                guard result.succeeded else { throw SCError("Couldn't sign \(name): \(result.error)") }
            }
            let used = signed == nil ? "ad hoc" : signer
            let usedStamp = SHA256.hash(data: code + plist + Data(used.utf8)).map { String(format: "%02x", $0) }.joined()
            try usedStamp.write(to: stampFile, atomically: true, encoding: .utf8)
            return used
        }
    }

    /// Where a runtime copy carries the tap: `.sc/SC Audio Tap.app`, its
    /// stamp beside it (`RuntimeCopy`).
    static let shippedPath = ".sc/\(name).app"

    /// Put this sc's tap, built and signed (`ensure`), in a runtime copy's
    /// staging folder, so the copy needn't build it.
    static func stage(into staging: URL, repo: URL, ui: UI) async throws {
        _ = try await ensure(repo: repo, ui: ui)
        let shipped = staging.appendingPathComponent(shippedPath)
        let files = FileManager.default
        try? files.removeItem(at: shipped)
        try files.createDirectory(at: shipped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: app, to: shipped)
        let stamp = shipped.deletingLastPathComponent().appendingPathComponent("\(name).stamp")
        try? files.removeItem(at: stamp)
        try files.copyItem(at: stampFile, to: stamp)
    }

    /// In a runtime copy: the tap it brought, installed into this user's
    /// folder unless that's the same build already (its stamp), so a
    /// permission given to it lasts until a new build arrives. It's signed
    /// as on the Mac that built it, with the identity a test user shares
    /// with the console user (`sc session add`), or ad hoc.
    static func installShipped(from shipped: URL) async throws -> String {
        let files = FileManager.default
        let shippedStamp = shipped.deletingLastPathComponent().appendingPathComponent("\(name).stamp")
        guard files.fileExists(atPath: shipped.path), let stamp = try? String(contentsOf: shippedStamp, encoding: .utf8) else {
            throw SCError("No audio tap to use: this copy brought none, and has no source to build one from.",
                          hints: ["Run it with sc --on from the Mac with the checkout, which builds the tap there and sends it."])
        }
        if (try? String(contentsOf: stampFile, encoding: .utf8)) != stamp || !files.isExecutableFile(atPath: executable.path) {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try? files.removeItem(at: app)
            try files.copyItem(at: shipped, to: app)
            try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        }
        return await signer(of: app)
    }

    /// Who signed `app`, as `codesign` names the first authority, or "ad hoc".
    static func signer(of app: URL) async -> String {
        guard let result = try? await Proc.collect("/usr/bin/codesign", ["-dvv", app.path]) else { return "ad hoc" }
        let authority = (result.output + result.error).split(separator: "\n").first { $0.hasPrefix("Authority=") }
        return authority.map { String($0.dropFirst("Authority=".count)) } ?? "ad hoc"
    }

    /// Runs it as its own responsible process, so macOS asks about the
    /// permission for it, not for sc. Its output, a line each.
    static func run(_ arguments: [String]) async throws -> (status: Int32, lines: [String]) {
        let collected = Lines()
        let status = try await Proc.stream(executable.path, arguments, disclaimResponsibility: true) { line in
            collected.append(line)
        }
        return (status, collected.all)
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }
}
