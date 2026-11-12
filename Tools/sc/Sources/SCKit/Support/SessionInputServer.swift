import Foundation
import WrappBuilder

/// The keep-alive's door for input into a test session: a Unix socket, one a
/// test user, that takes clicks, keys and text (`SessionInput`) and sends them
/// down the Screen Sharing connection the keep-alive already holds there. Only
/// that connection moves the session's pointer
/// (docs/wine-in-process-helpers.md#virtual-pointer), so this is the session's
/// mouse and keyboard, for `sc session do` and for anything run in the session.
///
/// The protocol: a JSON `SessionInputRequest` a line, each answered by a JSON
/// `SessionInputReply` line once it's been done; an empty line (or the end of
/// the input) ends the conversation. Only the keep-alive's user and the test
/// user themselves may connect.
final class SessionInputServer: @unchecked Sendable {
    static let folder = SharedFolders.root.appendingPathComponent("session-input", isDirectory: true)
    static func socketPath(for user: String, in folder: URL = folder) -> String { folder.appendingPathComponent("\(user).sock").path }

    /// A request waiting for the keep-alive's connection, and how its answer
    /// gets back to the client waiting for it.
    final class Job: @unchecked Sendable {
        let request: SessionInputRequest
        private let done = DispatchSemaphore(value: 0)
        private var error: String?
        init(_ request: SessionInputRequest) { self.request = request }
        func finish(error: String? = nil) {
            self.error = error
            done.signal()
        }
        func wait() -> String? {
            done.wait()
            return error
        }
    }

    private let user: String
    private let path: String
    private let listener: Int32
    private let allowed: Set<uid_t>
    private let lock = NSLock()
    private var queue: [Job] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var isConnected = false

    /// Listens on `user`'s socket, replacing any left by an earlier keep-alive.
    init(user: String, folder: URL = folder) throws {
        self.user = user
        var allowed: Set<uid_t> = [getuid()]
        if let entry = getpwnam(user) { allowed.insert(entry.pointee.pw_uid) }
        self.allowed = allowed
        try Self.makeFolder(folder)
        let path = Self.socketPath(for: user, in: folder)
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SCError("Couldn't open a socket for \(user)'s input: \(String(cString: strerror(errno))).") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw SCError("\(path) is too long for a socket's path.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Anyone may connect; who they are is checked once they have.
        guard bound == 0, chmod(path, 0o666) == 0, listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw SCError("Couldn't listen for \(user)'s input at \(path): \(reason).")
        }
        listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Stops listening; a client still connected is answered with an error.
    func close() {
        unlink(path)
        Darwin.close(listener)
        setConnected(false)
    }

    /// The folder, the keep-alive's own: in the shared root, whose ACL lets
    /// anyone replace anything, but without it, so nobody else can swap a
    /// socket in.
    private static func makeFolder(_ folder: URL) throws {
        let files = FileManager.default
        if folder == Self.folder, !files.fileExists(atPath: SharedFolders.root.path) {
            try files.createDirectory(at: SharedFolders.root, withIntermediateDirectories: true)
            _ = SessionPool.quickly("/bin/chmod", ["+a", SharedFolders.everyoneACL, SharedFolders.root.path])
        }
        // Every test user's task makes it at once: one that's there is fine.
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = SessionPool.quickly("/bin/chmod", ["-N", folder.path])
        chmod(folder.path, 0o755)
    }

    // MARK: The keep-alive's side

    /// Whether the keep-alive has a connection to send input down: without
    /// one, requests are turned away at once rather than kept waiting.
    func setConnected(_ connected: Bool) {
        let dropped: [Job] = lock.withLock {
            isConnected = connected
            guard !connected else { return [] }
            defer { queue.removeAll() }
            return queue
        }
        for job in dropped { job.finish(error: "the keep-alive lost its Screen Sharing connection to \(user)") }
    }

    /// The next request, waiting up to `seconds` for one.
    func next(within seconds: Double) async -> Job? {
        if let job = take() { return job }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if !queue.isEmpty { return true }
                waiter = continuation
                return false
            }
            if now { continuation.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in wake() }
        }
        return take()
    }

    private func take() -> Job? {
        lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
    }

    private func wake() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    // MARK: Clients

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // Closed.
            }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, allowed.contains(uid) else {
            reply(SessionInputReply(error: "only \(user) and the keep-alive's user may send input to \(user)'s session"), to: client)
            return
        }
        let input = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) { return }
                reply(handle(Data(line)), to: client)
                continue
            }
            guard let more = try? input.read(upToCount: 4096), !more.isEmpty else { return }
            buffer.append(more)
        }
    }

    private func handle(_ line: Data) -> SessionInputReply {
        let request: SessionInputRequest
        do {
            request = try JSONDecoder().decode(SessionInputRequest.self, from: line)
        } catch {
            return SessionInputReply(error: "couldn't read the request: \(error)")
        }
        let job = Job(request)
        let accepted: Bool = lock.withLock {
            guard isConnected else { return false }
            queue.append(job)
            return true
        }
        guard accepted else { return SessionInputReply(error: "the keep-alive isn't connected to \(user)'s session just now") }
        wake()
        return SessionInputReply(error: job.wait())
    }

    private func reply(_ reply: SessionInputReply, to client: Int32) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, data.count) }
    }
}

/// One thing to do in the session. `width`: how wide the picture `input`'s
/// points were read from is; without it, they're the screen's own pixels.
struct SessionInputRequest: Codable, Equatable {
    var input: SessionInput
    var width: Int?
}

/// Done, or why not.
struct SessionInputReply: Codable, Equatable {
    var error: String?
}
