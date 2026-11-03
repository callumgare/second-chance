//
//  DevToolsPage.swift
//  SecondChanceKit
//
//  A page in a Chromium-based (CEF) app, driven over Chromium's DevTools
//  protocol: Big Fish's Game Manager draws its whole window as one web page
//  and, started with --remote-debugging-port, lets anything on this Mac run
//  JavaScript in it. That's how a build reads its state and asks it to
//  download a game, without moving the mouse. See docs/big-fish.md.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.BigFish")

public actor DevToolsPage {
    public enum DevToolsError: Error, Equatable, CustomStringConvertible {
        /// Nothing answering on the port, or no page matching yet.
        case noPage
        /// The script threw; Chromium's description of it.
        case scriptFailed(String)
        /// An answer that wasn't what the protocol promises.
        case badResponse
        case timedOut

        public var description: String {
            switch self {
            case .noPage: "no page to drive yet"
            case .scriptFailed(let text): "script failed: \(text)"
            case .badResponse: "unexpected answer from the page"
            case .timedOut: "the page didn't answer in time"
            }
        }
    }

    public let port: Int
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var nextID = 0

    public init(port: Int) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    /// Connect to the app's first page whose URL `matches`. Throws `.noPage`
    /// when the app isn't listening yet or has no such page, for the caller
    /// to try again.
    public func connect(matching matches: @Sendable (String) -> Bool) async throws {
        let list = URL(string: "http://127.0.0.1:\(port)/json")!  // swiftlint:disable:this force_unwrapping
        let data: Data
        do {
            (data, _) = try await session.data(from: list)
        } catch {
            throw DevToolsError.noPage
        }
        guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let target = targets.first(where: { ($0["type"] as? String) == "page" && matches(($0["url"] as? String) ?? "") }),
              let address = target["webSocketDebuggerUrl"] as? String,
              let url = URL(string: address) else { throw DevToolsError.noPage }
        socket?.cancel()
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        self.socket = socket
        logger.debug("Connected to the page at \(target["url"] as? String ?? "?") on port \(port)")
    }

    public var isConnected: Bool { socket != nil }

    /// Run `expression` in the page, awaiting it when it's a promise, and
    /// decode what it returns (which must be JSON-able).
    public func evaluate<Value: Decodable & Sendable>(_ expression: String, as type: Value.Type,
                                                      timeout: TimeInterval = 60) async throws -> Value {
        let value = try await evaluateJSON(expression, timeout: timeout)
        do {
            return try JSONDecoder().decode(Value.self, from: value)
        } catch {
            throw DevToolsError.badResponse
        }
    }

    /// Run `expression` for what it does.
    public func run(_ expression: String, timeout: TimeInterval = 60) async throws {
        _ = try await evaluateJSON(expression, timeout: timeout)
    }

    public func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// The JSON of what `expression` returned (`null` for nothing).
    private func evaluateJSON(_ expression: String, timeout: TimeInterval) async throws -> Data {
        guard let socket else { throw DevToolsError.noPage }
        nextID += 1
        let id = nextID
        let request: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true, "awaitPromise": true],
        ]
        let message = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        do {
            try await socket.send(.string(message))
        } catch {
            self.socket = nil
            throw DevToolsError.noPage
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard Date() < deadline else { throw DevToolsError.timedOut }
            let received: URLSessionWebSocketTask.Message
            do {
                received = try await socket.receive()
            } catch {
                // The page went away (the app quit or reloaded it).
                self.socket = nil
                throw DevToolsError.noPage
            }
            let text: String
            switch received {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            // Events and other answers arrive on the same socket.
            guard let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  (reply["id"] as? Int) == id else { continue }
            return try Self.value(of: reply)
        }
    }

    /// The returned value of a `Runtime.evaluate` reply, as JSON.
    static func value(of reply: [String: Any]) throws -> Data {
        guard let result = reply["result"] as? [String: Any] else { throw DevToolsError.badResponse }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            let detail = (exception["exception"] as? [String: Any])?["description"] as? String
            throw DevToolsError.scriptFailed(detail ?? (exception["text"] as? String) ?? "exception")
        }
        guard let remote = result["result"] as? [String: Any] else { throw DevToolsError.badResponse }
        let value = remote["value"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    /// A TCP port on 127.0.0.1 nothing is listening on, for the app to listen
    /// on: each build's Game Manager gets its own, so builds side by side don't
    /// meet.
    public nonisolated static func freePort() -> Int? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
