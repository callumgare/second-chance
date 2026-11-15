//
//  MacScreenTests.swift
//  The wrapp's half of showing the Mac in its own window: the messages, and
//  the socket, with a descriptor passed as basilisk_display.m passes its
//  screen's.

import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing

@testable import BasiliskKit

struct MacScreenTests {
    @Test func messageRoundTrips() throws {
        let message = MacScreenMessage(.windowState, 1, 0, 1, -640, 480)
        #expect(message.encoded.count == MacScreenMessage.size)
        #expect(MacScreenMessage(message.encoded) == message)
    }

    @Test func messagePadsItsNumbers() {
        #expect(MacScreenMessage(.redraw).values == [0, 0, 0, 0, 0])
        #expect(MacScreenMessage(.mouse, 3, 4).values == [3, 4, 0, 0, 0])
    }

    @Test func unknownOrShortMessagesAreRefused() {
        var bytes = MacScreenMessage(.focus).encoded
        bytes[0] = 99
        #expect(MacScreenMessage(bytes) == nil)
        #expect(MacScreenMessage(Data(count: 12)) == nil)
    }

    @Test func framesSayWhatChanged() {
        guard case .frame(let changed, let covered)? = MacScreenServer.event(MacScreenMessage(.frame, 10, 20, 30, 40, 1), descriptor: -1) else {
            Issue.record("not a frame")
            return
        }
        #expect(changed == CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(covered)
        guard case .frame(nil, false)? = MacScreenServer.event(MacScreenMessage(.frame), descriptor: -1) else {
            Issue.record("a frame with no change should say so")
            return
        }
    }

    @Test func aScreenWithoutMemoryIsIgnored() {
        #expect(MacScreenServer.event(MacScreenMessage(.screen, 640, 480, 2560, Int32(bitPattern: MacScreenBuffer.argb8888)),
                                      descriptor: -1) == nil)
    }

    /// The helper's side, as basilisk_display.m does it: connects, says
    /// hello, sends its screen's memory as a descriptor, then a frame; then
    /// reads what the wrapp sends.
    @Test func helperAndWrappTalk() throws {
        let server = try MacScreenServer()
        defer { server.close() }
        let events = Mutex<[MacScreenEvent]>([])
        let screenSeen = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        server.start { event in
            events.withLock { $0.append(event) }
            if case .frame = event { screenSeen.signal() }
            if case .ended = event { ended.signal() }
        }

        let client = try #require(Self.connect(to: server.socketPath))
        defer { close(client) }
        // A 4x2 screen of BGRA8888 pixels, every one red (B G R A in memory is
        // A R G B as a 32-bit big-endian number).
        let memory = try #require(Self.screenMemory(bytes: Array(repeating: [0xFF, 0xFF, 0x00, 0x00], count: 8).flatMap { $0 }))
        #expect(Self.send(client, MacScreenMessage(.hello, 1234, 1)))
        #expect(Self.send(client, MacScreenMessage(.screen, 4, 2, 16, Int32(bitPattern: MacScreenBuffer.bgra8888)), descriptor: memory))
        close(memory)
        #expect(Self.send(client, MacScreenMessage(.frame, 0, 0, 4, 2, 0)))
        #expect(screenSeen.wait(timeout: .now() + 5) == .success)

        let seen = events.withLock { $0 }
        guard seen.count == 3, case .hello(1234, true) = seen[0], case .screen(let buffer) = seen[1] else {
            Issue.record("unexpected events: \(seen)")
            return
        }
        #expect(buffer.width == 4 && buffer.height == 2)
        let image = try #require(buffer.image())
        let pixel = try #require(Self.pixel(of: image))
        #expect(pixel == [255, 0, 0])

        server.key(0x7E, down: true)
        var reply = Data(count: MacScreenMessage.size)
        let count = reply.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, MSG_WAITALL) }
        #expect(count == MacScreenMessage.size)
        #expect(MacScreenMessage(reply) == MacScreenMessage(.key, 0x7E, 1))

        close(client)
        #expect(ended.wait(timeout: .now() + 5) == .success)
    }

    @Test func closingRemovesTheSocket() throws {
        let server = try MacScreenServer()
        let path = server.socketPath
        #expect(FileManager.default.fileExists(atPath: path))
        server.close()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func closingEndsAWaitingServer() throws {
        let server = try MacScreenServer()
        let ended = DispatchSemaphore(value: 0)
        server.start { event in
            if case .ended = event { ended.signal() }
        }
        server.close()
        #expect(ended.wait(timeout: .now() + 5) == .success)
    }

    @Test func closingEndsAConnectedServer() throws {
        let server = try MacScreenServer()
        let ended = DispatchSemaphore(value: 0)
        let hello = DispatchSemaphore(value: 0)
        server.start { event in
            if case .hello = event { hello.signal() }
            if case .ended = event { ended.signal() }
        }
        let client = try #require(Self.connect(to: server.socketPath))
        defer { close(client) }
        #expect(Self.send(client, MacScreenMessage(.hello, 1, 1)))
        #expect(hello.wait(timeout: .now() + 5) == .success)
        server.close()
        #expect(ended.wait(timeout: .now() + 5) == .success)
    }

    // MARK: - The helper's side

    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// A file holding the bytes, open, unlinked: memory to share, as the
    /// helper's shm_open is.
    private static func screenMemory(bytes: [UInt8]) -> Int32? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mac-screen-\(UUID().uuidString)").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return nil }
        unlink(path)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func send(_ fd: Int32, _ message: MacScreenMessage, descriptor: Int32 = -1) -> Bool {
        var bytes = message.encoded
        var control = [UInt8](repeating: 0, count: 16)
        if descriptor >= 0 {
            control.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt32(16), toByteOffset: 0, as: UInt32.self)
                raw.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
                raw.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
                raw.storeBytes(of: descriptor, toByteOffset: 12, as: Int32.self)
            }
        }
        let sent = bytes.withUnsafeMutableBytes { body in
            control.withUnsafeMutableBytes { controlBytes in
                var part = iovec(iov_base: body.baseAddress, iov_len: body.count)
                return withUnsafeMutablePointer(to: &part) { partPointer in
                    var header = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: partPointer, msg_iovlen: 1,
                                        msg_control: descriptor >= 0 ? controlBytes.baseAddress : nil,
                                        msg_controllen: descriptor >= 0 ? 16 : 0, msg_flags: 0)
                    return sendmsg(fd, &header, 0)
                }
            }
        }
        return sent == MacScreenMessage.size
    }

    /// The top-left pixel's red, green and blue.
    private static func pixel(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
        return Array(bytes.prefix(3))
    }
}
