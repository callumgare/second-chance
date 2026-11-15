//
//  MacScreen.swift
//  BasiliskKit
//
//  The wrapp's half of showing Basilisk II's Mac in a window of the wrapp's
//  own: the socket the in-process helper (basilisk_display.m) connects to,
//  the messages each way, and the screen it shares as memory
//  (docs/modules.md#the-mac-in-the-wrapps-window).

import CoreGraphics
import Darwin
import Foundation
import Synchronization

/// One message on the socket, either way: a kind and five numbers, 24 bytes
/// in this Mac's byte order. basilisk_display.m's `DisplayMessage` is the
/// other half; keep the two alike.
public nonisolated struct MacScreenMessage: Equatable, Sendable {
    public enum Kind: UInt32, Sendable {
        /// From the helper: its pid, and 1 when it shows the Mac here, 0 when
        /// Basilisk II's own window is to show it instead.
        case hello = 1
        /// From the helper, with the screen's shared memory as a descriptor:
        /// width, height, bytes per row, SDL pixel format.
        case screen = 2
        /// From the helper: what changed (x, y, width, height; width 0 when
        /// nothing did), and whether the Mac is covered (1/0).
        case frame = 3
        /// From the helper: puppet control's `focus`.
        case focus = 4
        /// From the helper: puppet control's `yield`, to pid values[0].
        case yield = 5
        /// To the helper: the pointer at x, y on the Mac's screen.
        case mouse = 10
        /// To the helper: button values[0] down (1) or up (0).
        case button = 11
        /// To the helper: a Mac virtual key code down (1) or up (0).
        case key = 12
        /// To the helper: the window fullscreen, key, the app active, and
        /// the window's width and height in points.
        case windowState = 13
        /// To the helper: the whole screen again.
        case redraw = 14
    }

    public static let size = 24

    public let kind: Kind
    public let values: [Int32]

    public init(_ kind: Kind, _ values: Int32...) {
        self.kind = kind
        self.values = (values + Array(repeating: 0, count: 5)).prefix(5).map { $0 }
    }

    /// From its 24 bytes; nil for a kind this doesn't know or a short read.
    public init?(_ bytes: Data) {
        guard bytes.count == Self.size else { return nil }
        let words = bytes.withUnsafeBytes { raw in (0..<6).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) } }
        guard let kind = Kind(rawValue: words[0]) else { return nil }
        self.kind = kind
        values = words.dropFirst().map { Int32(bitPattern: $0) }
    }

    public var encoded: Data {
        var data = Data(capacity: Self.size)
        for word in [kind.rawValue] + values.map({ UInt32(bitPattern: $0) }) {
            withUnsafeBytes(of: word) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// The Mac's screen as the helper keeps it: shared memory, mapped read-only,
/// a whole screen of 32-bit pixels.
public nonisolated final class MacScreenBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    /// SDL's pixel format: ARGB8888 or BGRA8888.
    public let format: UInt32
    private let base: UnsafeRawPointer
    private let length: Int

    static let argb8888: UInt32 = 0x1636_2004
    static let bgra8888: UInt32 = 0x1686_2004

    /// The memory the descriptor names, mapped; the descriptor is closed
    /// either way. Nil when the numbers don't fit it or it can't be mapped.
    public init?(descriptor: Int32, width: Int, height: Int, rowBytes: Int, format: UInt32) {
        defer { close(descriptor) }
        let length = rowBytes * height
        guard width > 0, height > 0, rowBytes >= width * 4, format == Self.argb8888 || format == Self.bgra8888 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, Int(status.st_size) >= length else { return nil }
        let mapped = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0)
        guard let mapped, mapped != MAP_FAILED else { return nil }
        base = UnsafeRawPointer(mapped)
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.format = format
        self.length = length
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }

    /// The screen now, as a picture of its own (a copy, so the Mac drawing
    /// on doesn't change it).
    public func image() -> CGImage? {
        let copy = Data(bytes: base, count: length)
        guard let provider = CGDataProvider(data: copy as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // ARGB8888 is a 32-bit ARGB number, BGRA8888 a BGRA one: in memory,
        // on this little-endian Mac, B G R A and A R G B.
        let order: CGBitmapInfo = format == Self.argb8888 ? .byteOrder32Little : .byteOrder32Big
        let info = CGBitmapInfo(rawValue: order.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// What the helper says, as the server reads it.
public nonisolated enum MacScreenEvent: Sendable {
    /// Whether it shows the Mac here (false: Basilisk II's own window will).
    case hello(pid: Int32, armed: Bool)
    /// A screen, new or of a new size.
    case screen(MacScreenBuffer)
    /// The Mac drew: what changed (nil when nothing did), and whether it's
    /// covered (to be shown black).
    case frame(changed: CGRect?, covered: Bool)
    case focus
    case yield(pid: Int32)
    /// The helper's gone, or never came: Basilisk II has quit, or the socket failed.
    case ended(String)
}

/// The socket the helper connects to: one connection, read on a thread of
/// its own, its events handed to `onEvent` on that thread.
public nonisolated final class MacScreenServer: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case socket(String)
        public var description: String {
            switch self {
            case .socket(let why): "The Mac's screen socket: \(why)"
            }
        }
    }

    /// Where it listens: BASILISK_MAC_DISPLAY for the helper.
    public let socketPath: String
    private let directory: URL
    private let listener: Int32
    /// The helper's connection: -1 before it comes, -2 once closed.
    private let connection = Mutex<Int32>(-1)

    /// Listening, in a new private directory under `parent` (a socket's path
    /// is limited to 103 bytes, so the temporary folder suits).
    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        var template = Array(parent.appendingPathComponent("sc-mac-XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw Failure.socket("no private directory: \(String(cString: strerror(errno)))") }
        directory = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        socketPath = directory.appendingPathComponent("screen.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("no socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw Failure.socket("its path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw Failure.socket("can't listen at \(socketPath): \(why)")
        }
        listener = fd
    }

    /// Waits for the helper on a thread of its own, then reads it until it
    /// goes, then says `.ended`.
    public func start(onEvent: @escaping @Sendable (MacScreenEvent) -> Void) {
        let thread = Thread { [self] in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                onEvent(.ended("nothing connected: \(String(cString: strerror(errno)))"))
                return
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Closed while it waited: -2 marks the server closed.
            let closed = connection.withLock { current -> Bool in
                guard current != -2 else { return true }
                current = fd
                return false
            }
            if closed {
                Darwin.close(fd)
                onEvent(.ended("the server was closed"))
                return
            }
            onEvent(.ended(read(fd, onEvent: onEvent)))
        }
        thread.name = "MacScreenServer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Reads messages until the connection ends; why it did.
    private func read(_ fd: Int32, onEvent: (MacScreenEvent) -> Void) -> String {
        while true {
            var bytes = Data(count: MacScreenMessage.size)
            var descriptor: Int32 = -1
            let count = bytes.withUnsafeMutableBytes { Self.receive(fd, into: $0, descriptor: &descriptor) }
            if count == 0 { return "the helper closed its connection" }
            if count < 0 { return "reading failed: \(String(cString: strerror(errno)))" }
            guard count == MacScreenMessage.size, let message = MacScreenMessage(bytes) else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                continue
            }
            if let event = Self.event(message, descriptor: descriptor) {
                onEvent(event)
            } else if descriptor >= 0 {
                Darwin.close(descriptor)
            }
        }
    }

    /// One message, whole (waiting for all its bytes), and the descriptor
    /// sent with it, if any.
    private static func receive(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, descriptor: inout Int32) -> Int {
        // A control message carrying one descriptor: a 12-byte cmsghdr, then
        // the int (CMSG_SPACE(sizeof(int)) is 16 here). Swift has no CMSG_
        // macros, so it's read by hand.
        var control = [UInt8](repeating: 0, count: 64)
        var part = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
        let received = control.withUnsafeMutableBytes { controlBytes -> Int in
            withUnsafeMutablePointer(to: &part) { partPointer -> Int in
                var header = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: partPointer, msg_iovlen: 1,
                                    msg_control: controlBytes.baseAddress, msg_controllen: socklen_t(controlBytes.count),
                                    msg_flags: 0)
                var count: Int
                repeat {
                    count = recvmsg(fd, &header, MSG_WAITALL)
                } while count < 0 && errno == EINTR
                if count > 0, header.msg_controllen >= 16 {
                    let length = controlBytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                    let level = controlBytes.loadUnaligned(fromByteOffset: 4, as: Int32.self)
                    let type = controlBytes.loadUnaligned(fromByteOffset: 8, as: Int32.self)
                    if level == SOL_SOCKET, type == SCM_RIGHTS, length >= 16 {
                        descriptor = controlBytes.loadUnaligned(fromByteOffset: 12, as: Int32.self)
                    }
                }
                return count
            }
        }
        return received
    }

    /// What a message from the helper means; nil for one to ignore.
    static func event(_ message: MacScreenMessage, descriptor: Int32) -> MacScreenEvent? {
        let values = message.values
        switch message.kind {
        case .hello: return .hello(pid: values[0], armed: values[1] != 0)
        case .screen:
            guard descriptor >= 0,
                  let buffer = MacScreenBuffer(descriptor: descriptor, width: Int(values[0]), height: Int(values[1]),
                                               rowBytes: Int(values[2]), format: UInt32(bitPattern: values[3])) else { return nil }
            return .screen(buffer)
        case .frame:
            let changed = values[2] > 0 && values[3] > 0
                ? CGRect(x: Int(values[0]), y: Int(values[1]), width: Int(values[2]), height: Int(values[3])) : nil
            return .frame(changed: changed, covered: values[4] != 0)
        case .focus: return .focus
        case .yield: return .yield(pid: values[0])
        case .mouse, .button, .key, .windowState, .redraw: return nil
        }
    }

    /// A message to the helper; false when there's none connected, or it's gone.
    @discardableResult
    public func send(_ message: MacScreenMessage) -> Bool {
        connection.withLock { fd in
            guard fd >= 0 else { return false }
            let bytes = message.encoded
            return bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } == bytes.count
        }
    }

    public func mouseMoved(x: Int, y: Int) { send(MacScreenMessage(.mouse, Int32(clamping: x), Int32(clamping: y))) }
    public func button(_ button: Int, down: Bool) { send(MacScreenMessage(.button, Int32(clamping: button), down ? 1 : 0)) }
    public func key(_ virtualKeyCode: UInt16, down: Bool) { send(MacScreenMessage(.key, Int32(virtualKeyCode), down ? 1 : 0)) }
    public func redraw() { send(MacScreenMessage(.redraw)) }
    public func windowState(fullscreen: Bool, key: Bool, active: Bool, width: Int, height: Int) {
        send(MacScreenMessage(.windowState, fullscreen ? 1 : 0, key ? 1 : 0, active ? 1 : 0,
                              Int32(clamping: width), Int32(clamping: height)))
    }

    /// Stop listening, end the connection, and remove the socket's directory.
    /// The helper, seeing the connection end, shuts the Mac down.
    public func close() {
        let first = connection.withLock { fd -> Bool in
            defer { fd = -2 }
            if fd >= 0 {
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            return fd != -2
        }
        guard first else { return }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }
}
