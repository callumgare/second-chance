//
//  AutomationBridge.swift
//  SecondChance
//
//  Unix-socket IPC bridge that streams AppEvents to automation clients as NDJSON.
//
//  ## Protocol
//  Each message is a JSON object on a single line (NDJSON / JSON Lines).
//  All messages share three reserved keys:
//    "kind"  — protocol-level discriminator: "event" | (future: "command" | "response")
//    "type"  — dotted-path identifier, e.g. "wrappBuild.gameDetected"
//    "t"     — ISO-8601 UTC timestamp
//  All other keys carry the payload for that specific message type.
//
//  ## Extending the protocol
//  New event types: add a case to the serialize*() switch statements.
//  New message kinds (e.g. "command"): add a receive loop on clientFD.
//
//  ## Activation
//  Set SC_AUTOMATION_SOCKET=/tmp/sc-auto-XXXX.sock before launch. The bridge
//  creates the socket file at that path, accepting one client at a time.

import Foundation
import Darwin
import GameCatalog
import SecondChanceKit

/// Env var that enables the automation bridge. Value: absolute Unix socket path.
nonisolated let automationSocketEnvVar = "SC_AUTOMATION_SOCKET"

/// Server-side IPC bridge. Serialises EventBus events to connected clients as NDJSON.
/// Thread-safe via NSLock; safe to call broadcast() from any thread/actor.
nonisolated final class AutomationBridge: @unchecked Sendable {
    static let shared = AutomationBridge()
    private init() {}

    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    /// Guards both descriptors: the accept loop's thread and the bus's
    /// handler reach them.
    private let fdLock = NSLock()
    /// Writes to the client go out on this queue, in order, so a client that
    /// stops reading holds up neither the bus nor the build.
    private let writes = DispatchQueue(label: "au.gare.callum.second-chance.AutomationBridge.writes")
    private var socketPath: String?
    private var busToken: EventBus<AppEvent>.Token?

    // MARK: - Lifecycle

    /// Start if SC_AUTOMATION_SOCKET is set; no-op otherwise.
    func startIfConfigured() async {
        guard let path = ProcessInfo.processInfo.environment[automationSocketEnvVar],
              !path.isEmpty else { return }
        await start(socketPath: path, bus: .app)
    }

    /// Create the socket, start accepting connections, and subscribe to the event bus.
    func start(socketPath: String, bus: EventBus<AppEvent>) async {
        self.socketPath = socketPath
        guard setupSocket(at: socketPath) else { return }
        Thread.detachNewThread { self.acceptLoop() }
        busToken = await bus.subscribe { [weak self] event in
            self?.broadcast(event)
        }
    }

    /// Flush a lifecycle.terminating message, close connections, remove the socket file.
    /// Call synchronously before _exit().
    func stop() {
        broadcastRaw(["kind": "event", "type": "lifecycle.terminating"])
        // Let that, and anything before it, go out first.
        writes.sync {}
        fdLock.withLock {
            if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }
            if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
        }
        if let path = socketPath { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: - Socket setup

    private func setupSocket(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path into the fixed-size sun_path tuple via a raw buffer.
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cStr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let len = min(strlen(cStr), pathCapacity - 1)
                buf.copyMemory(from: UnsafeRawBufferPointer(start: cStr, count: len))
            }
        }

        let bound = withUnsafePointer(to: &addr) { addrPtr -> Bool in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else { Darwin.close(fd); return false }
        Darwin.listen(fd, 1)
        fdLock.withLock { serverFD = fd }
        return true
    }

    // Runs on a dedicated thread; accept() blocks until a client connects.
    private func acceptLoop() {
        while true {
            let server = fdLock.withLock { serverFD }
            guard server >= 0 else { break }
            let fd = Darwin.accept(server, nil, nil)
            guard fd >= 0 else { break }
            // A client that goes away mid-write is an EPIPE, not a SIGPIPE
            // that would kill Second Chance.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            fdLock.withLock {
                if clientFD >= 0 { Darwin.close(clientFD) }
                clientFD = fd
            }
        }
    }

    // MARK: - Broadcasting

    private func broadcast(_ event: AppEvent) {
        guard let fields = serialize(event) else { return }
        broadcastRaw(fields)
    }

    private func broadcastRaw(_ fields: [String: Any]) {
        let fd = fdLock.withLock { clientFD }
        guard fd >= 0 else { return }

        var payload = fields
        payload["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = Data((json + "\n").utf8)
        writes.async { [weak self] in
            guard let self else { return }
            let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            // Gone: forget it, rather than write to a closed descriptor that
            // may since have been reused.
            if written < 0 {
                self.fdLock.withLock {
                    if self.clientFD == fd { Darwin.close(fd); self.clientFD = -1 }
                }
            }
        }
    }

    // MARK: - Serialisation

    private func serialize(_ event: AppEvent) -> [String: Any]? {
        switch event {
        case .wrappBuild(let e): return serializeWrappBuild(e)
        case .lifecycle(let e):    return serializeLifecycle(e)
        }
    }

    private func serializeWrappBuild(_ event: WrappBuildEvent) -> [String: Any]? {
        var d: [String: Any] = ["kind": "event"]
        switch event {
        case .started(let source):
            d["type"] = "wrappBuild.started"; d["source"] = source.rawValue
        case .isoMounted(let url):
            d["type"] = "wrappBuild.isoMounted"; d["mountPath"] = url.path
        case .disksResolved(let disk1, let disk2):
            d["type"] = "wrappBuild.disksResolved"; d["disk1Path"] = disk1.path
            if let disk2 { d["disk2Path"] = disk2.path }
        case .gameDetected(let info):
            d["type"] = "wrappBuild.gameDetected"
            d["gameId"] = info.id; d["gameTitle"] = info.title; d["engine"] = info.composition.engineTag
        case .engineRouted(let composition, let info):
            // `engine`, as the event has always had it, so recorded streams compare the same.
            d["type"] = "wrappBuild.engineRouted"
            d["engine"] = composition.engineTag; d["gameId"] = info.id
        case .installerResolved(let exePath, let type):
            d["type"] = "wrappBuild.installerResolved"
            d["exePath"] = exePath; d["installerType"] = "\(type)"
        case .gameExeDetected(let path, let info):
            d["type"] = "wrappBuild.gameExeDetected"
            d["exePath"] = path; d["gameId"] = info.id
        case .wrappConfigured(let exePath, let installerDir, let info):
            d["type"] = "wrappBuild.wrappConfigured"
            d["exePath"] = exePath; d["installerDir"] = installerDir; d["gameId"] = info.id
        case .signed(let url):
            d["type"] = "wrappBuild.signed"; d["wrappPath"] = url.path
        case .wrappStarted(let url):
            d["type"] = "wrappBuild.wrappStarted"; d["wrappPath"] = url.path
        case .patchApplied(let id):
            d["type"] = "wrappBuild.patchApplied"; d["patchId"] = id
        case .patchFailed(let id, let message):
            d["type"] = "wrappBuild.patchFailed"; d["patchId"] = id; d["error"] = message
        case .steamGamesOwned(let games):
            d["type"] = "wrappBuild.steamGamesOwned"; d["slugs"] = games.map(\.id)
        case .bigFishGamesOwned(let games):
            d["type"] = "wrappBuild.bigFishGamesOwned"; d["slugs"] = games.map(\.id)
        case .completed(let url):
            d["type"] = "wrappBuild.completed"; d["wrappPath"] = url.path
        case .failed(let error):
            d["type"] = "wrappBuild.failed"; d["error"] = error.localizedDescription
        case .instructions(let text):
            d["type"] = "wrappBuild.instructions"
            if let text { d["text"] = text }
        case .stepProgress(let progress):
            d["type"] = "wrappBuild.stepProgress"
            if let progress {
                d["text"] = progress.text
                if let fraction = progress.fraction { d["fraction"] = fraction }
            }
        case .steamSignInNotice(let notice):
            d["type"] = "wrappBuild.steamSignInNotice"
            if let notice { d["notice"] = "\(notice)" }
        case .progress(let state):
            d["type"] = "wrappBuild.progress"; d["state"] = "\(state)"
            if let sub = state.substep { d["substep"] = sub }
        }
        return d
    }

    private func serializeLifecycle(_ event: LifecycleEvent) -> [String: Any]? {
        switch event {
        case .launched:    return ["kind": "event", "type": "lifecycle.launched"]
        case .terminating: return ["kind": "event", "type": "lifecycle.terminating"]
        }
    }
}
