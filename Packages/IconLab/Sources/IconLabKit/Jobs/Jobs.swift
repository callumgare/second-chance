import Foundation

/// Background work the page shows: each job has a title, a state, progress and an ETA. Listeners get every change
/// (the server forwards them to the page's WebSocket).
public actor Jobs {
    public struct Job: Codable, Sendable {
        public var id: String
        public var program: String?
        public var title: String
        public var state: String          // queued | running | done | failed
        public var progress: Double
        public var eta: Double?
        public var detail: String?
        public var group: String?
        public var source: String?          // the source a gather job is for
        public var started: Date?
        public var finished: Date?
    }

    public typealias Listener = @Sendable (Data) -> Void
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var listeners: [UUID: Listener] = [:]
    private var running = 0
    private var waiting: [(String, @Sendable () async throws -> Void)] = []
    public let width: Int

    public init(width: Int = 3) { self.width = width }

    public func listen(_ l: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = l
        return id
    }

    public func unlisten(_ id: UUID) { listeners[id] = nil }

    public func all() -> [Job] { order.compactMap { jobs[$0] } }

    /// Sends any event to every listener.
    public func broadcast(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        for l in listeners.values { l(data) }
    }

    /// Sends an already-encoded event to every listener.
    public func broadcastData(_ data: Data) {
        for l in listeners.values { l(data) }
    }

    func publish(_ j: Job) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let jd = try? e.encode(j), let jo = try? JSONSerialization.jsonObject(with: jd) else { return }
        broadcast(["type": "job", "job": jo])
    }

    /// Queues work; it runs when a slot is free. `work` gets a progress callback (0…1, optional ETA in seconds).
    @discardableResult
    public func enqueue(title: String, program: String? = nil, group: String? = nil, source: String? = nil,
                        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double, String?) async -> Void) async throws -> Void) -> String {
        let id = UUID().uuidString.lowercased()
        let job = Job(id: id, program: program, title: title, state: "queued", progress: 0, group: group, source: source)
        jobs[id] = job
        order.append(id)
        if order.count > 300 { let drop = order.removeFirst(); jobs[drop] = nil }
        publish(job)
        waiting.append((id, { [weak self] in
            guard let self else { return }
            try await work { p, detail in await self.progress(id, p, detail) }
        }))
        pump()
        return id
    }

    /// Starts work at once, outside the queue's slots, still shown as a job. For work that queued jobs wait on (a
    /// model download that analysis jobs need): queued behind them, it could wait for ever.
    @discardableResult
    public func start(title: String, program: String? = nil, group: String? = nil,
                      _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double, String?) async -> Void) async throws -> Void) -> String {
        let id = UUID().uuidString.lowercased()
        let job = Job(id: id, program: program, title: title, state: "running", progress: 0, group: group, started: Date())
        jobs[id] = job
        order.append(id)
        if order.count > 300 { let drop = order.removeFirst(); jobs[drop] = nil }
        publish(job)
        Task.detached { [self] in
            var failure: String?
            do { try await work { p, detail in await self.progress(id, p, detail) } } catch { failure = "\(error)" }
            await self.finish(id, failure, slotted: false)
        }
        return id
    }

    private func pump() {
        while running < width, !waiting.isEmpty {
            let (id, work) = waiting.removeFirst()
            running += 1
            jobs[id]?.state = "running"
            jobs[id]?.started = Date()
            if let j = jobs[id] { publish(j) }
            Task.detached { [weak self] in
                var failure: String?
                do { try await work() } catch { failure = "\(error)" }
                await self?.finish(id, failure)
            }
        }
    }

    private func progress(_ id: String, _ p: Double, _ detail: String?) {
        guard var j = jobs[id] else { return }
        j.progress = max(0, min(1, p))
        if let detail { j.detail = detail }
        if let s = j.started, p > 0.02 { j.eta = Date().timeIntervalSince(s) * (1 - p) / p }
        jobs[id] = j
        publish(j)
    }

    private func finish(_ id: String, _ failure: String?, slotted: Bool = true) {
        if slotted { running -= 1 }
        if var j = jobs[id] {
            j.state = failure == nil ? "done" : "failed"
            j.progress = failure == nil ? 1 : j.progress
            j.detail = failure ?? j.detail
            j.eta = nil
            j.finished = Date()
            jobs[id] = j
            publish(j)
        }
        pump()
    }
}
