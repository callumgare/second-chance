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
        public var scan: String?            // the scan a scan job runs (its `scan` events)
        public var started: Date?
        public var finished: Date?
    }

    public typealias Listener = @Sendable (Data) -> Void
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var listeners: [UUID: Listener] = [:]
    /// Work runs in lanes, each with its own slots, so one kind never waits behind another: a scan of your files
    /// doesn't queue behind gathering that's waiting on a catalogue's rate limit, nor gathering behind analysis.
    public enum Lane: Sendable, CaseIterable {
        /// Waiting on the network (gathering from a source, finding a program in the catalogues, updating a
        /// catalogue's copy): many at once, as each mostly waits and each source paces itself.
        case network
        /// Scanning the person's files: unpacking and reading the disk.
        case files
        /// Everything else (analysis, hi-res, cut-outs): the CPU and the models, held to a share of the cores.
        case compute

        static func of(_ group: String?) -> Lane {
            switch group {
            case "gather", "match", "sources": .network
            case "scan": .files
            default: .compute
            }
        }
    }

    private var running: [Lane: Int] = [:]
    private var waiting: [(id: String, lane: Lane, work: @Sendable () async throws -> Void)] = []
    private var lanes: [String: Lane] = [:]
    /// Running jobs' tasks, so a job can be cancelled.
    private var tasks: [String: Task<Void, Never>] = [:]
    /// How many of each lane's jobs run at once.
    public let widths: [Lane: Int]
    /// The compute lane's width.
    public var width: Int { widths[.compute] ?? 1 }

    public init(width: Int = 3, network: Int = 8, files: Int = 2) {
        widths = [.compute: max(1, width), .network: max(1, network), .files: max(1, files)]
    }

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
    public func enqueue(title: String, program: String? = nil, group: String? = nil, source: String? = nil, scan: String? = nil,
                        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double, String?) async -> Void) async throws -> Void) -> String {
        let id = UUID().uuidString.lowercased()
        let job = Job(id: id, program: program, title: title, state: "queued", progress: 0, group: group, source: source, scan: scan)
        jobs[id] = job
        order.append(id)
        publish(job)
        let lane = Lane.of(group)
        lanes[id] = lane
        waiting.append((id, lane, { [weak self] in
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
        publish(job)
        tasks[id] = Task.detached { [self] in
            var failure: String?
            do { try await work { p, detail in await self.progress(id, p, detail) } } catch { failure = Self.failure(error) }
            await self.finish(id, failure, slotted: false)
        }
        return id
    }

    /// Starts what's waiting, in order, in each lane with a slot free.
    private func pump() {
        while let i = waiting.firstIndex(where: { running[$0.lane, default: 0] < widths[$0.lane, default: 1] }) {
            let (id, lane, work) = waiting.remove(at: i)
            running[lane, default: 0] += 1
            jobs[id]?.state = "running"
            jobs[id]?.started = Date()
            if let j = jobs[id] { publish(j) }
            tasks[id] = Task.detached { [weak self] in
                var failure: String?
                do { try await work() } catch { failure = Self.failure(error) }
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

    /// Cancels a job: a queued one never starts, and a running one's task is cancelled, so work that checks stops
    /// (a scan, a download). False when there's no such job, or it has finished.
    @discardableResult
    public func cancel(_ id: String) -> Bool {
        if let i = waiting.firstIndex(where: { $0.id == id }) {
            let lane = waiting.remove(at: i).lane
            running[lane, default: 0] += 1   // finish takes the slot back
            finish(id, Self.cancelled)
            return true
        }
        guard let task = tasks[id] else { return false }
        task.cancel()
        return true
    }

    static let cancelled = "cancelled"

    nonisolated static func failure(_ error: any Error) -> String {
        error is CancellationError ? cancelled : "\(error)"
    }

    private func finish(_ id: String, _ failure: String?, slotted: Bool = true) {
        tasks[id] = nil
        if slotted, let lane = lanes.removeValue(forKey: id) { running[lane, default: 1] -= 1 }
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
