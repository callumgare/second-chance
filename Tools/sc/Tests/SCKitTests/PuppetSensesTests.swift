import CoreGraphics
import Foundation
import ImageIO
@testable import SCKit
import Testing

@Suite struct PuppetSensesTests {
    @Test func findsTheProcessesUnderTheWrapp() {
        let listing = """
            1     0
          100     1
          101   100
          102   101
          200     1
          103   100
        """
        #expect(ProcessTree.descendants(of: 100, in: ProcessTree.parse(listing)) == [100, 101, 103, 102])
    }

    // MARK: Recording and the sheet

    @Test func chaptersRunFromEachActionToTheNext() {
        let start = Date(timeIntervalSince1970: 1000)
        let actions = [PuppetAction(time: start.addingTimeInterval(2), action: "click 10 20"),
                       PuppetAction(time: start.addingTimeInterval(5), action: "key return")]
        let chapters = PuppetMovie.chapters(actions, started: start, duration: 8)
        #expect(chapters.map(\.title) == ["start", "click 10 20", "key return"])
        #expect(chapters.map(\.start) == [0, 2, 5])
        #expect(chapters.map(\.end) == [2, 5, 8])
        #expect(PuppetMovie.chapters([], started: start, duration: 3).map(\.title) == ["start"])
    }

    @Test func actionsAreReadBackInTheirWindow() {
        let text = """
        {"action":"click 1 2","time":"2026-11-05T10:00:00Z"}
        not json
        {"action":"key a","time":"2026-11-05T10:00:05Z"}
        """
        let actions = PuppetAction.parse(text)
        #expect(actions.map(\.action) == ["click 1 2", "key a"])
    }

    @Test func recordingsScaleNeverAboveTheWindows() {
        #expect(PuppetMovie.scale(window: (1280, 720, 2), longEdge: 960) == 0.75)
        #expect(PuppetMovie.scale(window: (320, 200, 1), longEdge: 960) == 1)
    }

    @Test func sinceTakesATimeOfDayOrAWhileAgo() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14, minute: 30)))
        #expect(PuppetSheet.since("90s", now: now) == now.addingTimeInterval(-90))
        #expect(PuppetSheet.since("2m", now: now) == now.addingTimeInterval(-120))
        #expect(PuppetSheet.since("14:05:30", now: now) == Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14, minute: 5, second: 30)))
        #expect(PuppetSheet.since("soon", now: now) == nil)
    }

    @Test func theSheetShowsFramesThatChangedSpreadEvenly() {
        let black = [UInt8](repeating: 0, count: 64 * 36)
        let white = [UInt8](repeating: 255, count: 64 * 36)
        #expect(PuppetSheet.shows(black, after: nil, threshold: 5))
        #expect(!PuppetSheet.shows(black, after: black, threshold: 5))
        #expect(PuppetSheet.shows(white, after: black, threshold: 5))
        #expect(PuppetSheet.spread(Array(0..<10), count: 4) == [0, 3, 6, 9])
        #expect(PuppetSheet.spread(Array(0..<3), count: 4) == [0, 1, 2])
    }

    /// A movie written from frames reads back with its frames, their times
    /// and its chapters; the sheet draws them.
    @Test func aMovieRoundTripsWithChapters() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("puppet-senses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var frames: [(time: Double, file: URL)] = []
        for index in 0..<6 {
            let file = folder.appendingPathComponent("\(index).png")
            try PuppetSheet.writePNG(try #require(Self.solid(grey: index < 3 ? 1 : 0)), to: file)
            frames.append((Double(index) * 0.5 + 0.035, file))
        }
        let movie = folder.appendingPathComponent("test.mov")
        let chapters = [(start: 0.0, end: 1.5, title: "start"), (start: 1.5, end: 3.0, title: "click 10 20")]
        let size = try await PuppetMovie.write(to: movie, frames: frames, chapters: chapters, duration: 3)
        #expect(size.width == 160 && size.height == 90)

        let titles = try await PuppetMovie.chapterTitles(of: movie)
        #expect(titles.map(\.title) == ["start", "click 10 20"])
        #expect(titles.map(\.start) == [0, 1.5])

        var times: [Double] = [], thumbnails: [[UInt8]] = [], images: [CGImage] = []
        try await PuppetMovie.frames(of: movie) { time, image in
            times.append(time)
            if let thumbnail = Frames.thumbnail(image), PuppetSheet.shows(thumbnail, after: thumbnails.last, threshold: 5) {
                thumbnails.append(thumbnail)
                images.append(image)
            }
        }
        #expect(times.count == 6)
        #expect(times.first == 0)
        #expect(abs((times.last ?? 0) - 2.535) < 0.01)
        #expect(thumbnails.count == 2)
        // The first frame is the first picture, not a blank one.
        #expect(Frames.black(thumbnails.first ?? []) == 0)

        let start = Date()
        let tiles = images.enumerated().map { PuppetSheet.Tile(time: start.addingTimeInterval(Double($0.offset)), image: $0.element, after: ["key a"]) }
        let sheet = try #require(PuppetSheet.draw(tiles, columns: 4, tileWidth: 160, started: start))
        #expect(sheet.width == 2 * 160 + 3 * 6)
    }

    static func solid(grey: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        return context.makeImage()
    }
}

extension PuppetSensesTests {
    @Test func actionTimesKeepTheirMilliseconds() throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000.345)
        let data = try PreciseDates.encoder().encode(PuppetAction(time: time, action: "key a"))
        let back = PuppetAction.parse(String(decoding: data, as: UTF8.self))
        #expect(abs((back.first?.time.timeIntervalSince1970 ?? 0) - 1_800_000_000.345) < 0.002)
        #expect(PuppetAction.parse(#"{"action":"key a","time":"2026-11-05T10:00:00Z"}"#).count == 1)
    }
}
