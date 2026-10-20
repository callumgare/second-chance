//
//  InProcessControl.swift
//  WrappPuppeteer
//
//  The client side of the control sockets an app under test serves for its
//  own windows. A process may capture and click its own windows with no
//  permission, so rather than WrappPuppeteer needing Screen Recording and
//  Accessibility to act on them from outside, the app does it and answers
//  over a Unix socket: one request per connection, one line each way, replies
//  starting `ok` or `error`.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.InProcessControl")

/// One app's control socket.
struct ControlSocket {
    let path: String

    /// Whether something has created the socket. It may not be listening yet.
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Send `line` and return the reply, without its newline; nil if nothing
    /// is listening, or nothing came back within `timeout`.
    func request(_ line: String, timeout: TimeInterval = 40) -> String? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            logger.error("Socket path too long for a Unix socket: \(path)")
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let written = (line + "\n").withCString { write(descriptor, $0, strlen($0)) }
        guard written > 0 else { return nil }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
            if buffer[count - 1] == UInt8(ascii: "\n") { break }
        }
        guard !reply.isEmpty else {
            logger.warning("No reply to '\(line)' from \(path) within \(Int(timeout))s")
            return nil
        }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `key=value` fields of an `ok` reply; nil for an error or no reply.
    static func fields(of reply: String?) -> [String: String]? {
        guard let reply, reply == "ok" || reply.hasPrefix("ok ") else { return nil }
        var fields: [String: String] = [:]
        for part in reply.split(separator: " ").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }
}

/// What a window control reports about the window it serves.
struct ControlledWindowState {
    let windowNumber: Int
    /// In points.
    let size: CGSize
    /// Pixels per point.
    let scale: CGFloat
    /// In a macOS fullscreen Space, or exactly covering its screen.
    let fullscreen: Bool
    /// In a macOS fullscreen Space.
    let native: Bool
    let key: Bool
    let active: Bool
    /// The app has hidden the cursor and confined it to its window.
    let cursorHeld: Bool
    /// What the app's own cursor-locking, if it has any, says it is doing;
    /// nil when the app doesn't say.
    let cursorLock: String?
}

/// A window served over a control socket: `state`, `capture <path>`,
/// `click <x> <y>` and `move <x> <y>`, in window points with a top-left
/// origin — a capture's pixels divided by its scale.
struct WindowControl {
    let socket: ControlSocket

    func state() -> ControlledWindowState? {
        guard let fields = ControlSocket.fields(of: socket.request("state", timeout: 10)),
              let window = fields["window"].flatMap(Int.init),
              let sizeParts = fields["size"]?.split(separator: "x"), sizeParts.count == 2,
              let width = Double(sizeParts[0]), let height = Double(sizeParts[1]),
              let scale = fields["scale"].flatMap(Double.init) else { return nil }
        return ControlledWindowState(
            windowNumber: window, size: CGSize(width: width, height: height), scale: CGFloat(scale),
            fullscreen: fields["fullscreen"] == "1", native: fields["native"] == "1",
            key: fields["key"] == "1", active: fields["active"] == "1",
            cursorHeld: fields["cursor"] == "held", cursorLock: fields["cursorlock"])
    }

    /// Capture the window to a PNG at `path`; its size in pixels, or nil.
    func capture(to path: String) -> CGSize? {
        let started = Date()
        let reply = socket.request("capture \(path)")
        let seconds = Date().timeIntervalSince(started)
        if seconds > 5 {
            logger.warning("Capturing the window took \(String(format: "%.1f", seconds))s — a slow capture on every app suggests systemstatusd (docs/testing.md)")
        }
        guard let reply, reply.hasPrefix("ok "),
              let sizeParts = reply.dropFirst(3).split(separator: " ").first?.split(separator: "x"), sizeParts.count == 2,
              let width = Double(sizeParts[0]), let height = Double(sizeParts[1]) else {
            logger.warning("Capture failed: \(reply ?? "no reply")")
            return nil
        }
        return CGSize(width: width, height: height)
    }

    @discardableResult
    func click(at point: CGPoint) -> Bool {
        report(socket.request("click \(point.x) \(point.y)"), for: "click")
    }

    @discardableResult
    func move(to point: CGPoint) -> Bool {
        report(socket.request("move \(point.x) \(point.y)"), for: "move")
    }

    private func report(_ reply: String?, for request: String) -> Bool {
        guard reply == "ok" else {
            logger.warning("\(request) failed: \(reply ?? "no reply")")
            return false
        }
        return true
    }
}
