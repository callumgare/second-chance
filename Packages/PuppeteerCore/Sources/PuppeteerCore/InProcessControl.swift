//
//  InProcessControl.swift
//  WrappPuppeteer
//
//  The client side of the control sockets an app under test serves for its
//  own windows. A process may capture and click its own windows with no
//  permission, so rather than WrappPuppeteer needing Screen Recording and
//  Accessibility to act on them from outside, the app does it and answers
//  over a Unix socket: one request per connection, one line each way, replies
//  starting `ok` or `error`. The requests and their replies are
//  PuppetProtocol's (Packages/PuppetProtocol), shared with `sc puppet`.

import CoreGraphics
import Foundation
import Logging
import PuppetProtocol

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.InProcessControl")

/// One app's control socket.
nonisolated public struct ControlSocket: Sendable {
    public let path: String

    /// Whether something has created the socket. It may not be listening yet.
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Send a request to the in-process helper; nil if nothing is listening,
    /// or nothing came back within `timeout`.
    public func request(_ request: PuppetRequest, timeout: TimeInterval = 40) -> PuppetReply? {
        send(request.line, timeout: timeout)
    }

    /// Send a request to the wrapp's own socket; nil as above.
    public func request(_ request: WrappRequest, timeout: TimeInterval = 40) -> PuppetReply? {
        send(request.line, timeout: timeout)
    }

    private func send(_ line: String, timeout: TimeInterval) -> PuppetReply? {
        do {
            return try PuppetSocket(path: path).send(line: line, timeout: timeout)
        } catch let failure as PuppetSocket.Failure {
            if case .noReply = failure { logger.warning("\(failure)") }
            if case .pathTooLong = failure { logger.error("\(failure)") }
            return nil
        } catch {
            return nil
        }
    }

    public init(path: String) {
        self.path = path
    }
}

/// What a window control reports about the window it serves.
public typealias ControlledWindowState = PuppetWindowState

/// A window served over a control socket (PuppetProtocol has the requests):
/// points in the window, top-left origin — a capture's pixels divided by its
/// scale.
nonisolated public struct WindowControl: Sendable {
    public let socket: ControlSocket

    public func state() -> ControlledWindowState? {
        socket.request(.state, timeout: 10).flatMap(PuppetWindowState.init)
    }

    /// Capture the window to a PNG at `path`; its size in pixels, or nil.
    public func capture(to path: String) -> CGSize? {
        let started = Date()
        let reply = socket.request(.capture(path: path))
        let seconds = Date().timeIntervalSince(started)
        if seconds > 5 {
            logger.warning("Capturing the window took \(String(format: "%.1f", seconds))s — a slow capture on every app suggests systemstatusd (docs/testing.md)")
        }
        guard let reply, reply.isOK, let size = reply.size else {
            logger.warning("Capture failed: \(reply?.text ?? "no reply")")
            return nil
        }
        return size
    }

    @discardableResult
    public func click(at point: CGPoint) -> Bool {
        send(.click(point))
    }

    /// Press keys in a key sequence's canonical form
    /// (`KeySequence.canonical(defaultGapMilliseconds:)`, or one press as
    /// `KeySequence.Step.notation` writes it: `escape`, `cmd+q`,
    /// `f12:hold=1000ms`: docs/wrappfile.md#key-sequences). A helper from
    /// before keys (protocol 1) answers with an error.
    @discardableResult
    public func press(_ keys: String) -> Bool {
        // Held long enough for a game that polls the keyboard each frame.
        let request = PuppetRequest.key(keys, hold: 150)
        return send(request, timeout: request.timeout)
    }

    @discardableResult
    public func move(to point: CGPoint) -> Bool {
        send(.move(point))
    }

    /// Ask the window's app to quit, as its Quit menu item does.
    @discardableResult
    public func quitApp() -> Bool {
        send(.quit)
    }

    /// Listen to the window's app for `seconds`, from inside its process
    /// (a Wine game's helper, protocol 4): its levels, or why it couldn't.
    public func listen(seconds: Double) -> Result<PuppetAudio, PuppetProtocolError> {
        guard let reply = socket.request(.audio(seconds: seconds), timeout: seconds + 20) else {
            return .failure(PuppetProtocolError("no reply to audio"))
        }
        guard let audio = PuppetAudio(reply) else { return .failure(PuppetProtocolError(reply.error ?? reply.text)) }
        return .success(audio)
    }

    /// Hand activation from the window's app to the app with `pid`, which
    /// can then make itself active: since macOS 14 only the active app may
    /// hand it on.
    @discardableResult
    public func yieldActivation(to pid: pid_t) -> Bool {
        send(.yield(pid: pid))
    }

    private func send(_ request: PuppetRequest, timeout: TimeInterval = 40) -> Bool {
        let reply = socket.request(request, timeout: timeout)
        guard let reply, reply.isOK else {
            logger.warning("\(request.verb) failed: \(reply?.text ?? "no reply")")
            return false
        }
        return true
    }

    public init(socket: ControlSocket) {
        self.socket = socket
    }
}
