//
//  PuppetSocket.swift
//  PuppetProtocol
//
//  Sending one request to a control socket and reading its reply. The
//  helper and the wrapp each close the connection once they've replied, so
//  the reply is everything read until then.

import Foundation

nonisolated public struct PuppetSocket: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Whether something has made the socket; it may not be listening yet.
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case pathTooLong(String)
        case notListening(String, reason: String)
        case noReply(String, request: String, seconds: Int)
        case socket(String)

        public var description: String {
            switch self {
            case let .pathTooLong(path): "Socket path too long for a Unix socket: \(path)"
            case let .notListening(path, reason): "Nothing is listening on \((path as NSString).lastPathComponent): \(reason)."
            case let .noReply(path, request, seconds):
                "\((path as NSString).lastPathComponent) gave no answer to `\(request)` in \(seconds) s."
            case let .socket(reason): "Couldn't open a socket: \(reason)."
            }
        }
    }

    public func send(_ request: PuppetRequest, timeout: TimeInterval = 45) throws -> PuppetReply {
        try send(line: request.line, timeout: timeout)
    }

    public func send(_ request: WrappRequest, timeout: TimeInterval = 45) throws -> PuppetReply {
        try send(line: request.line, timeout: timeout)
    }

    /// Send a line as it is, and read the reply.
    public func send(line: String, timeout: TimeInterval = 45) throws -> PuppetReply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.notListening(path, reason: String(cString: strerror(errno))) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let out = Array((line + "\n").utf8)
        let written = out.withUnsafeBytes { write(descriptor, $0.baseAddress, out.count) }
        guard written > 0 else { throw Failure.notListening(path, reason: String(cString: strerror(errno))) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: reply, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.noReply(path, request: line, seconds: Int(timeout))
        }
        return PuppetReply(text)
    }
}
