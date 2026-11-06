import CoreGraphics
import Foundation
import PuppetProtocol
import ImageIO
import Vision

/// A program run for an agent to drive by hand (`sc puppet`): a wrapp started
/// in this user's GUI session with the in-process helper armed, a server that
/// holds the screen lease and stops it when it's idle, and files the commands
/// share. See docs/dev-cli.md#puppet-sessions.
struct PuppetSession: Codable {
    var name: String
    /// The wrapp it runs, or the program a command starts.
    var app: String
    /// A program run by hand (an engine) rather than a wrapp: its arguments,
    /// the first the executable.
    var command: [String]?
    /// The in-process helper inserted into `command`.
    var helper: String?
    var purpose: String?
    var started: Date
    var idleMinutes: Double
    var maxMinutes: Double
    var serverPID: Int32?
    var wrappPID: Int32?
    /// The screen was held from `started` to this, once it's stopped.
    var stopped: Date?
    var stopReason: String?

    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SecondChance/puppet")

    static func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
    var folder: URL { Self.folder(name) }
    var file: URL { folder.appendingPathComponent("session.json") }
    /// Touched by every command; the server stops the program when it's idle.
    var lastUsedFile: URL { folder.appendingPathComponent("last-used") }
    /// Its presence asks the server to stop.
    var stopFile: URL { folder.appendingPathComponent("stop") }
    var serverLog: URL { folder.appendingPathComponent("server.log") }
    var wrappLog: URL { folder.appendingPathComponent("wrapp.log") }
    var helpersLog: URL { folder.appendingPathComponent("helpers.log") }
    var appSupport: URL { folder.appendingPathComponent("app-support") }
    var shots: URL { folder.appendingPathComponent("shots") }
    /// HOME for a command, so an engine's settings and saves start empty
    /// and stay out of the user's own.
    var home: URL { folder.appendingPathComponent("home") }
    /// Short, as a Unix socket's path must be (104 bytes with the helper's
    /// `game-<pid>.sock`), and private to this user.
    var sockets: URL { URL(fileURLWithPath: "/tmp/sc-puppet-\(getuid())-\(name)") }

    static let label = "au.gare.callum.second-chance.puppet."

    static func validName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9-]{0,30}$"#, options: .regularExpression) != nil
    }

    static func load(_ name: String) throws -> PuppetSession {
        let file = folder(name).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: file) else {
            throw SCError("No puppet session named \(name).", hints: ["See them: sc puppet list", "Start one: sc puppet start \(name) --wrapp <app>"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PuppetSession.self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    static func all() -> [PuppetSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { try? load($0) }
    }

    var isRunning: Bool {
        guard stopped == nil, let pid = serverPID else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func touch() {
        FileManager.default.createFile(atPath: lastUsedFile.path, contents: nil)
    }

    var idleSince: Date {
        ((try? lastUsedFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? started
    }

    // MARK: The helper

    /// The game's socket: of the helpers listening, the one whose process has
    /// a window (an Armadillo-wrapped game runs two, only one with a window).
    func gameSocket() throws -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sockets.path)) ?? []
        let candidates = names.filter { $0.hasPrefix("game") && $0.hasSuffix(".sock") }.sorted()
            .map { sockets.appendingPathComponent($0) }
        guard !candidates.isEmpty else {
            throw SCError("\(name)'s game isn't answering yet: no helper socket in \(sockets.path).",
                          hints: ["Its log: sc puppet log \(name)", "Its state: sc puppet status \(name)"])
        }
        return candidates.first { (try? HelperSocket.ask($0, .state)).flatMap(PuppetWindowState.init) != nil } ?? candidates[0]
    }

    var wrappSocket: URL { sockets.appendingPathComponent("wrapp.sock") }

    func ask(_ request: PuppetRequest, timeout: TimeInterval = 45) throws -> PuppetReply {
        let reply = try HelperSocket.ask(try gameSocket(), request, timeout: timeout)
        guard reply.isOK else { throw SCError("The game's helper said: \(reply.text)") }
        return reply
    }
}

/// One request to a control socket, the helper's or the wrapp's
/// (PuppetProtocol has them), and its reply.
enum HelperSocket {
    static func ask(_ socketURL: URL, _ request: PuppetRequest, timeout: TimeInterval = 45) throws -> PuppetReply {
        try send(socketURL, request.line, timeout: timeout)
    }

    static func ask(_ socketURL: URL, _ request: WrappRequest, timeout: TimeInterval = 45) throws -> PuppetReply {
        try send(socketURL, request.line, timeout: timeout)
    }

    private static func send(_ socketURL: URL, _ line: String, timeout: TimeInterval) throws -> PuppetReply {
        do {
            return try PuppetSocket(path: socketURL.path).send(line: line, timeout: timeout)
        } catch let failure as PuppetSocket.Failure {
            throw SCError(failure.description)
        }
    }
}

/// What the pictures say, measured rather than looked at.
enum Frames {
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Grey levels at 64x36, the size change is judged at.
    static func thumbnail(_ image: CGImage, width: Int = 64, height: Int = 36) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// `image` `factor` times bigger, each pixel a block: for reading pixel
    /// fonts. nil when it needs no enlarging.
    static func enlarged(_ image: CGImage, by factor: Int) -> CGImage? {
        guard factor > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
        return context.makeImage()
    }

    /// The share of the picture that changed, 0–100: the thumbnail's pixels
    /// that moved by more than a little.
    static func changed(_ before: [UInt8], _ after: [UInt8]) -> Int {
        guard before.count == after.count, !before.isEmpty else { return 100 }
        let moved = zip(before, after).filter { abs(Int($0) - Int($1)) > 24 }.count
        return Int((Double(moved) * 100 / Double(before.count)).rounded())
    }

    /// The share of the picture that changed, 0–100, to a tenth: an action's
    /// reply says a change under 1% is there rather than rounding it away.
    static func changedShare(_ before: [UInt8], _ after: [UInt8]) -> Double {
        guard before.count == after.count, !before.isEmpty else { return 100 }
        let moved = zip(before, after).filter { abs(Int($0) - Int($1)) > 24 }.count
        return (Double(moved) * 1000 / Double(before.count)).rounded() / 10
    }

    /// Where the picture changed, as a box of a `width` by `height`
    /// thumbnail's pixels from its top left; nil when nothing did. A menu's
    /// highlight moving changes little of the picture, but in one place.
    static func changedBox(_ before: [UInt8], _ after: [UInt8], width: Int, height: Int) -> CGRect? {
        guard before.count == after.count, before.count == width * height else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for index in 0..<before.count where abs(Int(before[index]) - Int(after[index])) > 24 {
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The share that's black, 0–100.
    static func black(_ pixels: [UInt8]) -> Int {
        guard !pixels.isEmpty else { return 0 }
        return Int((Double(pixels.filter { $0 < 12 }.count) * 100 / Double(pixels.count)).rounded())
    }

    /// What Opus reads a picture of this size as costing: 28-pixel tiles,
    /// after it's fitted within a 2576-pixel long edge.
    static func tokens(width: Int, height: Int) -> Int {
        let fit = min(1, 2576 / Double(max(width, height)))
        let w = Double(width) * fit, h = Double(height) * fit
        return Int((w / 28).rounded(.up) * (h / 28).rounded(.up))
    }

    /// The lines of text Vision finds, with their boxes in the picture's
    /// pixels from the top left.
    ///
    /// Vision's current recogniser judges the page's orientation from all the
    /// text it sees, and nothing overrides that. A picture full of glyph-like
    /// shapes can tip it into reading every line upside down: on Iji's menu,
    /// whose background rains T and ⊥, "MAIN MENU" came back as "ONEH NIHH",
    /// or not at all, on two frames of five. Revision 2 reads upright text
    /// only and read all five, but the current one is kept for its better
    /// recognition elsewhere; such pictures should be rare.
    static func text(in image: CGImage) throws -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let width = Double(image.width), height = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return (best.string, CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                        width: box.width * width, height: box.height * height).integral)
        }
    }
}
