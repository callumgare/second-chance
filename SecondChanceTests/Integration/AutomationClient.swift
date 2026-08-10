//
//  AutomationClient.swift
//  SecondChanceTests
//
//  Client-side counterpart to AutomationBridge. Connects to the Unix socket,
//  reads NDJSON lines, and makes them available as a typed collection.
//
//  Typical usage (via SecondChanceRunner):
//    let runner = try await SecondChanceRunner.launch(...)
//    let (exitCode, events) = try await runner.waitForCompletion(timeout: 600)
//    let detected = events.first(ofType: "installation.gameDetected")
//    #expect(detected?.string(for: "gameId") == game.id)

import Foundation
import Darwin
import Testing

// MARK: - AutomationMessage

/// A single parsed NDJSON message from the Second Chance automation socket.
/// Fields beyond "kind", "type", and "t" are stored in `fields` and accessed
/// via typed accessors. Unknown fields round-trip safely; parsers ignore extras.
struct AutomationMessage: Sendable {
    /// Protocol-level discriminator. Currently always "event".
    let kind: String
    /// Dotted-path type, e.g. "installation.gameDetected", "lifecycle.terminating".
    let type: String
    let timestamp: Date
    /// All payload fields (everything except kind, type, t).
    let fields: [String: Any]

    init?(jsonData: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let kind = raw["kind"] as? String,
              let type = raw["type"] as? String
        else { return nil }
        self.kind = kind
        self.type = type
        self.timestamp = (raw["t"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        } ?? Date()
        var f = raw
        f.removeValue(forKey: "kind"); f.removeValue(forKey: "type"); f.removeValue(forKey: "t")
        self.fields = f
    }

    func string(for key: String) -> String? { fields[key] as? String }
    func url(for key: String) -> URL? { (fields[key] as? String).map { URL(fileURLWithPath: $0) } }
    func int(for key: String) -> Int? { fields[key] as? Int }
    func bool(for key: String) -> Bool? { fields[key] as? Bool }
}

extension Array where Element == AutomationMessage {
    /// First event with the given type, or nil.
    func first(ofType type: String) -> AutomationMessage? {
        first { $0.type == type }
    }

    /// All events with the given type.
    func all(ofType type: String) -> [AutomationMessage] {
        filter { $0.type == type }
    }

    /// Types in order — useful for asserting event ordering.
    var types: [String] { map(\.type) }
}

// MARK: - AutomationClient

/// Connects to the Second Chance automation socket and buffers all incoming events.
/// Returned by `SecondChanceRunner.launch`. Call `collectAll()` to block until EOF
/// (i.e. until the server process exits and closes the socket).
final class AutomationClient: @unchecked Sendable {
    private let fileHandle: FileHandle

    init(socketPath: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationError.socketCreationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cStr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let len = min(strlen(cStr), pathCapacity - 1)
                buf.copyMemory(from: UnsafeRawBufferPointer(start: cStr, count: len))
            }
        }

        let connected = withUnsafePointer(to: &addr) { addrPtr -> Bool in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { Darwin.close(fd); throw AutomationError.connectionFailed }
        fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Read all events until EOF (the server closes the socket).
    /// Blocks cooperatively via Swift concurrency — does not spin.
    func collectAll() async -> [AutomationMessage] {
        var results: [AutomationMessage] = []
        var buffer = Data()
        do {
            for try await byte in fileHandle.bytes {
                if byte == UInt8(ascii: "\n") {
                    if !buffer.isEmpty {
                        if let msg = AutomationMessage(jsonData: buffer) { results.append(msg) }
                        buffer.removeAll(keepingCapacity: true)
                    }
                } else {
                    buffer.append(byte)
                }
            }
        } catch {}
        // Flush any partial line without trailing newline (shouldn't happen, but safe).
        if !buffer.isEmpty, let msg = AutomationMessage(jsonData: buffer) { results.append(msg) }
        return results
    }
}

// MARK: - Errors

enum AutomationError: Error, LocalizedError {
    case socketCreationFailed
    case connectionFailed
    case connectionTimeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed: "Failed to create Unix domain socket"
        case .connectionFailed:     "Failed to connect to automation socket"
        case .connectionTimeout(let t): "Timed out connecting after \(t)s"
        }
    }
}
