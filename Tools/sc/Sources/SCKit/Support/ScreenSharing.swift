import CommonCrypto
import CryptoKit
import Foundation

/// Just enough of macOS Screen Sharing's protocol (RFB, with Apple's own
/// login) to log a test user in, unlock their session and keep it drawing:
/// a session whose viewer leaves is locked, and a locked one never moves a
/// game into its fullscreen Space. See docs/dev-cli.md#test-sessions.
final class ScreenSharingConnection {
    private let socket: Int32
    private(set) var width = 0
    private(set) var height = 0

    /// Connects to this Mac's Screen Sharing and logs `user` in, which starts
    /// their GUI session if they have none.
    init(user: String, password: String, host: String = "127.0.0.1", port: UInt16 = 5900) throws {
        socket = try Self.connect(host: host, port: port)
        do {
            try handshake(user: user, password: password)
        } catch {
            close(socket)
            throw error
        }
    }

    deinit { close(socket) }

    // MARK: The login

    private func handshake(user: String, password: String) throws {
        _ = try read(12)  // Apple's server says "RFB 003.889"; 3.8 is what we speak.
        try write(Array("RFB 003.008\n".utf8))
        let count = Int(try read(1)[0])
        guard count > 0 else { throw SCError("Screen Sharing refused the connection: \(try readReason())") }
        let types = try read(count)
        guard types.contains(Self.appleLogin) else {
            throw SCError("Screen Sharing doesn't offer Apple's login (it offered \(types)). Is Remote Management on instead?")
        }
        try write([Self.appleLogin])
        let header = try read(4)
        let generator = Data(header[0..<2])
        let keyLength = Int(header[2]) << 8 | Int(header[3])
        let prime = Data(try read(keyLength))
        let serverKey = Data(try read(keyLength))
        guard let arithmetic = ModularArithmetic(modulus: prime) else {
            throw SCError("Screen Sharing sent a key exchange sc can't use (an even modulus).")
        }
        let secret = Self.randomBytes(keyLength)
        let ourKey = arithmetic.power(generator, secret)
        let shared = arithmetic.power(serverKey, secret)
        let key = Data(Insecure.MD5.hash(data: shared))
        let credentials = try Self.encrypt(Self.credentials(user: user, password: password), key: key)
        try write(Array(credentials) + Array(ourKey))
        if try readUInt32() != 0 {
            throw SCError("Screen Sharing didn't accept \(user)'s password: \(try readReason())")
        }
        try write([1])  // Shared: leave anyone else connected.
        let size = try read(4)
        width = Int(size[0]) << 8 | Int(size[1])
        height = Int(size[2]) << 8 | Int(size[3])
        _ = try read(16)  // Its pixel format: ours replaces it.
        _ = try read(Int(try readUInt32()))  // The desktop's name.
        // 32-bit pixels and raw rectangles alone, so whatever arrives can be skipped.
        try write([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        try write([2, 0, 0, 1, 0, 0, 0, 0])
    }

    static let appleLogin: UInt8 = 30

    /// The user name and password, each in a 64-byte field ended by a NUL and
    /// padded with random bytes, as Apple's login wants them.
    static func credentials(user: String, password: String) -> Data {
        func field(_ text: String) -> Data {
            var bytes = Data(text.utf8.prefix(63))
            bytes.append(0)
            return bytes + randomBytes(64 - bytes.count)
        }
        return field(user) + field(password)
    }

    /// From the system's generator, which is cryptographically secure.
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// AES-128 in ECB mode, which is what the login uses.
    static func encrypt(_ data: Data, key: Data) throws -> Data {
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil, input.baseAddress, data.count,
                            output.baseAddress, data.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw SCError("Couldn't encrypt the Screen Sharing login (CommonCrypto \(status)).") }
        return out
    }

    // MARK: Keeping it drawing

    /// Asks for a small corner of the screen and reads until it comes: what a
    /// viewer does, so the session keeps drawing.
    func refresh() throws {
        try write([3, 0, 0, 0, 0, 0, 0, 8, 0, 8])
        while true {
            switch try read(1)[0] {
            case 0:
                let header = try read(3)
                for _ in 0..<(Int(header[1]) << 8 | Int(header[2])) {
                    let rect = try read(12)
                    let rectWidth = Int(rect[4]) << 8 | Int(rect[5])
                    let rectHeight = Int(rect[6]) << 8 | Int(rect[7])
                    let encoding = Int32(bitPattern: UInt32(rect[8]) << 24 | UInt32(rect[9]) << 16 | UInt32(rect[10]) << 8 | UInt32(rect[11]))
                    switch encoding {
                    case 0: _ = try read(rectWidth * rectHeight * 4)
                    case -223: width = rectWidth; height = rectHeight
                    default: throw SCError("Screen Sharing sent rectangles in encoding \(encoding), which wasn't asked for.")
                    }
                }
                return
            case 1:
                let header = try read(5)
                _ = try read((Int(header[3]) << 8 | Int(header[4])) * 6)
            case 2:
                continue  // A bell.
            case 3:
                _ = try read(3)
                _ = try read(Int(try readUInt32()))
            case let other:
                throw SCError("Screen Sharing sent message type \(other), which sc doesn't know.")
            }
        }
    }

    /// Unlocks the session's lock screen: a click on the user's picture
    /// (bottom centre) opens the password field, then the password and Return.
    func unlock(password: String) throws {
        let x = UInt16(width / 2), y = UInt16(Double(height) * 0.845)
        for buttons: UInt8 in [0, 1, 0] {
            try write([5, buttons, UInt8(x >> 8), UInt8(x & 0xFF), UInt8(y >> 8), UInt8(y & 0xFF)])
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 2)
        for keysym in password.unicodeScalars.map(\.value) + [0xFF0D] {
            for down: UInt8 in [1, 0] {
                try write([4, down, 0, 0, UInt8(keysym >> 24), UInt8((keysym >> 16) & 0xFF), UInt8((keysym >> 8) & 0xFF), UInt8(keysym & 0xFF)])
            }
        }
    }

    // MARK: The socket

    private static func connect(host: String, port: UInt16) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SCError("Couldn't open a socket: \(String(cString: strerror(errno))).") }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(socket)
            throw SCError("Couldn't reach Screen Sharing at \(host):\(port): \(reason).",
                          hints: ["Turn it on: System Settings → General → Sharing → Screen Sharing."])
        }
        return socket
    }

    private func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress.map { $0 + got }, count - got) }
            guard n > 0 else {
                throw SCError(n == 0 ? "Screen Sharing closed the connection." : "Reading from Screen Sharing failed: \(String(cString: strerror(errno))).")
            }
            got += n
        }
        return bytes
    }

    private func write(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(socket, $0.baseAddress.map { $0 + sent }, bytes.count - sent) }
            guard n > 0 else { throw SCError("Writing to Screen Sharing failed: \(String(cString: strerror(errno))).") }
            sent += n
        }
    }

    private func readUInt32() throws -> UInt32 {
        try read(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func readReason() throws -> String {
        String(decoding: try read(Int(try readUInt32())), as: UTF8.self)
    }
}

/// Powers modulo an odd number, by Montgomery multiplication on 32-bit limbs:
/// the Diffie-Hellman exchange Apple's login starts with, and nothing else.
/// Numbers come and go as big-endian bytes, as the protocol carries them.
struct ModularArithmetic {
    /// Little-endian limbs.
    private let modulus: [UInt32]
    private let byteCount: Int
    /// -modulus⁻¹ mod 2³².
    private let inverse: UInt32
    /// R² mod modulus, R = 2^(32·limbs).
    private let rSquared: [UInt32]

    init?(modulus bytes: Data) {
        let limbs = Self.limbs(bytes, count: (bytes.count + 3) / 4)
        guard let low = limbs.first, low & 1 == 1 else { return nil }
        modulus = limbs
        byteCount = bytes.count
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- low &* inverse) }
        self.inverse = 0 &- inverse
        // Double 1 modulo m 2·32·n times: 2^(64n) mod m.
        var value = [UInt32](repeating: 0, count: limbs.count + 1)
        value[0] = 1
        for _ in 0..<(64 * limbs.count) {
            var carry: UInt32 = 0
            for index in value.indices {
                let next = value[index] >> 31
                value[index] = value[index] << 1 | carry
                carry = next
            }
            if !Self.less(value, than: limbs) { Self.subtract(limbs, from: &value) }
        }
        rSquared = Array(value.prefix(limbs.count))
    }

    /// base^exponent mod modulus, as many bytes as the modulus has.
    func power(_ base: Data, _ exponent: Data) -> Data {
        let count = modulus.count
        var one = [UInt32](repeating: 0, count: count)
        one[0] = 1
        let base = multiply(Self.limbs(base, count: count), rSquared)
        var result = multiply(one, rSquared)
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = multiply(result, result)
                if byte >> bit & 1 == 1 { result = multiply(result, base) }
            }
        }
        return Self.bytes(multiply(result, one), count: byteCount)
    }

    /// a·b·R⁻¹ mod m (CIOS).
    private func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let count = modulus.count
        var t = [UInt32](repeating: 0, count: count + 2)
        for i in 0..<count {
            var carry: UInt64 = 0
            for j in 0..<count {
                let sum = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + carry
                t[j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var sum = UInt64(t[count]) + carry
            t[count] = UInt32(truncatingIfNeeded: sum)
            t[count + 1] = UInt32(sum >> 32)
            let factor = t[0] &* inverse
            sum = UInt64(t[0]) + UInt64(factor) * UInt64(modulus[0])
            carry = sum >> 32
            for j in 1..<count {
                sum = UInt64(t[j]) + UInt64(factor) * UInt64(modulus[j]) + carry
                t[j - 1] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            sum = UInt64(t[count]) + carry
            t[count - 1] = UInt32(truncatingIfNeeded: sum)
            t[count] = t[count + 1] &+ UInt32(sum >> 32)
            t[count + 1] = 0
        }
        var result = Array(t.prefix(count + 1))
        if !Self.less(result, than: modulus) { Self.subtract(modulus, from: &result) }
        return Array(result.prefix(count))
    }

    /// value < other, where value may have more limbs.
    private static func less(_ value: [UInt32], than other: [UInt32]) -> Bool {
        for index in stride(from: value.count - 1, through: 0, by: -1) {
            let right = index < other.count ? other[index] : 0
            if value[index] != right { return value[index] < right }
        }
        return false
    }

    private static func subtract(_ other: [UInt32], from value: inout [UInt32]) {
        var borrow: Int64 = 0
        for index in value.indices {
            let difference = Int64(value[index]) - Int64(index < other.count ? other[index] : 0) - borrow
            value[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
    }

    static func limbs(_ bytes: Data, count: Int) -> [UInt32] {
        var limbs = [UInt32](repeating: 0, count: count)
        for (offset, byte) in bytes.reversed().enumerated() where offset / 4 < count {
            limbs[offset / 4] |= UInt32(byte) << (8 * UInt32(offset % 4))
        }
        return limbs
    }

    static func bytes(_ limbs: [UInt32], count: Int) -> Data {
        Data((0..<count).reversed().map { offset in
            offset / 4 < limbs.count ? UInt8(truncatingIfNeeded: limbs[offset / 4] >> (8 * UInt32(offset % 4))) : 0
        })
    }
}
