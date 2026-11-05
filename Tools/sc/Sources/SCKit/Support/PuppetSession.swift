import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A program run for an agent to drive by hand (`sc puppet`): a wrapp started
/// in this user's GUI session with the in-process helper armed, a server that
/// holds the screen lease and stops it when it's idle, and files the commands
/// share. See docs/dev-cli.md#puppet-sessions.
struct PuppetSession: Codable {
    var name: String
    /// The wrapp it runs.
    var app: String
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
        return candidates.first { (try? HelperSocket.ask($0, "state"))?.hasPrefix("ok window=") == true } ?? candidates[0]
    }

    var wrappSocket: URL { sockets.appendingPathComponent("wrapp.sock") }

    func ask(_ request: String, timeout: TimeInterval = 45) throws -> String {
        let reply = try HelperSocket.ask(try gameSocket(), request, timeout: timeout)
        guard reply.hasPrefix("ok") else { throw SCError("The game's helper said: \(reply)") }
        return reply
    }
}

/// One request to an in-process helper's Unix socket, and its reply.
enum HelperSocket {
    static func ask(_ socketURL: URL, _ request: String, timeout: TimeInterval = 45) throws -> String {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SCError("Couldn't open a socket: \(String(cString: strerror(errno))).") }
        defer { close(socket) }
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SCError("Socket path too long: \(socketURL.path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            throw SCError("Nothing is listening on \(socketURL.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        let line = Array((request + "\n").utf8)
        _ = line.withUnsafeBytes { write(socket, $0.baseAddress, line.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, 4096) }
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SCError("\(socketURL.lastPathComponent) gave no answer to `\(request)` in \(Int(timeout)) s.") }
        return text
    }
}

/// What the pictures say, measured rather than looked at.
enum Frames {
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Grey levels at 64x36, the size change is judged at.
    static func thumbnail(_ image: CGImage) -> [UInt8]? {
        let width = 64, height = 36
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

    /// The share of the picture that changed, 0–100: the thumbnail's pixels
    /// that moved by more than a little.
    static func changed(_ before: [UInt8], _ after: [UInt8]) -> Int {
        guard before.count == after.count, !before.isEmpty else { return 100 }
        let moved = zip(before, after).filter { abs(Int($0) - Int($1)) > 24 }.count
        return Int((Double(moved) * 100 / Double(before.count)).rounded())
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
