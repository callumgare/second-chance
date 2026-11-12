import CoreML
import CryptoKit
import Foundation
import Logging
import ProcessKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Models")

/// Downloads, checks, compiles and keeps the models in `ModelManifest`, each the first time something needs it.
///
/// `data/models/<name>/` holds, while downloading, `download/<file>.part` (resumed with a Range request after an
/// interruption); once every file's size and SHA-256 match, a compiled `<name>.mlmodelc` (or, for plain data,
/// the files themselves) and `ready.json`. The downloaded `.mlpackage` is removed after compiling, so a model
/// takes its download's size on disk once. A download runs as a job (group `models`) so the activity panel shows
/// it; it starts outside the job queue's slots, as the jobs that need the model may be holding them all.
public actor ModelStore {
    public struct Status: Codable, Sendable {
        public var name: String
        public var purpose: String
        public var size: Int
        public var licence: String
        public var source: String
        public var state: String           // absent | downloading | compiling | ready | failed
        public var progress: Double?       // while downloading, 0…1
        public var error: String?
    }

    public let root: URL
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var progress: [String: Double] = [:]
    private var compiling: Set<String> = []
    private var failures: [String: String] = [:]
    private var loaded: [String: LoadedModel] = [:]
    private var listeners: [@Sendable (Status) async -> Void] = []

    public init(root: URL) {
        self.root = root
    }

    // MARK: One store per folder

    private static let registry = Registry()
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: ModelStore] = [:]
        func store(_ root: URL) -> ModelStore {
            lock.lock(); defer { lock.unlock() }
            if let s = stores[root.path] { return s }
            let s = ModelStore(root: root)
            stores[root.path] = s
            return s
        }
    }

    /// The store for a folder, shared by everything in this process that asks for it.
    public static func shared(root: URL) -> ModelStore { registry.store(root.standardizedFileURL) }

    // MARK: Status

    public func dir(_ name: String) -> URL { root.appendingPathComponent(name) }
    func compiledURL(_ name: String) -> URL { dir(name).appendingPathComponent("\(name).mlmodelc") }
    func readyFile(_ name: String) -> URL { dir(name).appendingPathComponent("ready.json") }

    public func isReady(_ name: String) -> Bool { FileManager.default.fileExists(atPath: readyFile(name).path) }

    public func status(_ name: String) -> Status? {
        guard let s = ModelManifest.spec(name) else { return nil }
        var st = Status(name: s.name, purpose: s.purpose, size: s.size, licence: s.licence, source: s.source, state: "absent")
        if isReady(name) {
            st.state = "ready"
        } else if compiling.contains(name) {
            st.state = "compiling"
        } else if inFlight[name] != nil {
            st.state = "downloading"
            st.progress = progress[name] ?? 0
        } else if let e = failures[name] {
            st.state = "failed"
            st.error = e
        }
        return st
    }

    public func statuses() -> [Status] { ModelManifest.all.compactMap { status($0.name) } }

    /// Called with a model's status whenever it changes (the server forwards these as `model` events).
    public func onChange(_ f: @escaping @Sendable (Status) async -> Void) { listeners.append(f) }

    private func changed(_ name: String) async {
        guard let s = status(name) else { return }
        for l in listeners { await l(s) }
    }

    // MARK: Getting a model

    /// The model's folder once it's ready (for `.data` models, where its files are), downloading and compiling it
    /// first if need be. Several callers asking at once share one download.
    public func ensure(_ name: String, jobs: Jobs) async throws -> URL {
        guard let spec = ModelManifest.spec(name) else { throw IconLabError.notFound("model \(name)") }
        if isReady(name) { return spec.format == .data ? dir(name) : compiledURL(name) }
        return try await begin(spec, jobs: jobs).value
    }

    /// Starts fetching a model if it isn't here or on its way, and says where it stands. Doesn't wait.
    @discardableResult
    public func startDownload(_ name: String, jobs: Jobs) -> Status? {
        guard let spec = ModelManifest.spec(name) else { return nil }
        if !isReady(name) { _ = begin(spec, jobs: jobs) }
        return status(name)
    }

    /// The download in flight for a model, started here if there's none. Synchronous, so two callers can't both
    /// start one; the task tidies up after itself, whether or not anyone waits for it.
    private func begin(_ spec: ModelSpec, jobs: Jobs) -> Task<URL, Error> {
        if let t = inFlight[spec.name] { return t }
        let name = spec.name
        failures[name] = nil
        let task = Task<URL, Error> {
            await self.changed(name)
            do {
                let url = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    Task {
                        await jobs.start(title: "Downloading the \(spec.name) model (\(Self.megabytes(spec.size)))", group: "models") { report in
                            do {
                                let url = try await self.fetch(spec) { p, detail in await report(p, detail) }
                                cont.resume(returning: url)
                            } catch {
                                cont.resume(throwing: error)
                                throw error
                            }
                        }
                    }
                }
                await self.settle(name, failure: nil)
                return url
            } catch {
                await self.settle(name, failure: "\(error)")
                throw error
            }
        }
        inFlight[name] = task
        return task
    }

    private func settle(_ name: String, failure: String?) async {
        inFlight[name] = nil
        progress[name] = nil
        failures[name] = failure
        await changed(name)
    }

    /// The loaded model, on the Neural Engine or GPU where Core ML can. Kept loaded once asked for.
    public func model(_ name: String, jobs: Jobs) async throws -> LoadedModel {
        if let m = loaded[name] { return m }
        let url = try await ensure(name, jobs: jobs)
        let config = MLModelConfiguration()
        // ICONLAB_MODELS_COMPUTE (all, cpuAndGPU, cpuOnly, cpuAndNeuralEngine) overrides the manifest, for experiments.
        let units = ProcessInfo.processInfo.environment["ICONLAB_MODELS_COMPUTE"] ?? ModelManifest.spec(name)?.computeUnits ?? "all"
        config.computeUnits = ["cpuAndGPU": .cpuAndGPU, "cpuOnly": .cpuOnly, "cpuAndNeuralEngine": .cpuAndNeuralEngine][units] ?? .all
        let m: MLModel
        do {
            m = try await MLModel.load(contentsOf: url, configuration: config)
        } catch {
            // A compiled model from another macOS can refuse to load: compile again from a fresh download next time.
            try? FileManager.default.removeItem(at: dir(name))
            throw IconLabError.tool("couldn't load the \(name) model: \(error)")
        }
        let lm = LoadedModel(name: name, model: m)
        loaded[name] = lm
        return lm
    }

    /// Removes a model's files (it downloads again when next needed).
    public func remove(_ name: String) async throws {
        guard inFlight[name] == nil else { throw IconLabError.invalid("\(name) is downloading") }
        loaded[name] = nil
        failures[name] = nil
        try? FileManager.default.removeItem(at: dir(name))
        await changed(name)
    }

    // MARK: Download, check, compile

    private func setProgress(_ name: String, _ p: Double) async {
        let before = progress[name] ?? -1
        progress[name] = p
        if p - before >= 0.02 || p >= 1 { await changed(name) }
    }

    private func setCompiling(_ name: String, _ on: Bool) async {
        if on { compiling.insert(name) } else { compiling.remove(name) }
        await changed(name)
    }

    private func fetch(_ spec: ModelSpec, report: @escaping @Sendable (Double, String?) async -> Void) async throws -> URL {
        let fm = FileManager.default
        let base = dir(spec.name)
        let dl = base.appendingPathComponent("download")
        try fm.createDirectory(at: dl, withIntermediateDirectories: true)
        let total = Double(spec.size)
        var done = 0
        for f in spec.files {
            let dest = dl.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path), (try? Self.sha256(of: dest)) == f.sha256 { done += f.size; continue }
            guard let url = URL(string: f.url) else { throw IconLabError.invalid("model URL \(f.url)") }
            let before = done
            try await FileDownload.fetch(url, to: dest, size: f.size, sha256: f.sha256) { got in
                let p = Double(before + got) / total
                await self.setProgress(spec.name, p * 0.9)
                await report(p * 0.9, "\(Self.megabytes(before + got)) of \(Self.megabytes(spec.size))")
            }
            done += f.size
        }
        await report(0.92, spec.format == .data ? "Checking" : "Compiling")
        let out: URL
        switch spec.format {
        case .data:
            for f in spec.files {
                let dest = base.appendingPathComponent(f.path)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: dl.appendingPathComponent(f.path), to: dest)
            }
            out = base
        case .mlpackage, .zippedMLPackage:
            var package = dl
            if spec.format == .zippedMLPackage, let zip = spec.files.first {
                let unz = base.appendingPathComponent("unzipped")
                try? fm.removeItem(at: unz)
                try await Self.unzip(dl.appendingPathComponent(zip.path), to: unz)
                guard let p = try fm.contentsOfDirectory(at: unz, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "mlpackage" }) else { throw IconLabError.tool("no .mlpackage in \(zip.path)") }
                package = p
            } else {
                // Core ML wants the folder to be named .mlpackage.
                let p = base.appendingPathComponent("\(spec.name).mlpackage")
                try? fm.removeItem(at: p)
                try fm.moveItem(at: dl, to: p)
                package = p
            }
            await setCompiling(spec.name, true)
            defer { Task { await self.setCompiling(spec.name, false) } }
            let tmp = try await MLModel.compileModel(at: package)
            let dest = compiledURL(spec.name)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            try? fm.removeItem(at: package)
            try? fm.removeItem(at: base.appendingPathComponent("unzipped"))
            out = dest
        }
        try? fm.removeItem(at: dl)
        let ready: [String: Any] = ["name": spec.name, "files": spec.files.map { ["path": $0.path, "sha256": $0.sha256] },
                                    "ready": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]).write(to: readyFile(spec.name), options: .atomic)
        await report(1, "Ready")
        return out
    }

    static func unzip(_ zip: URL, to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await Process.output(of: "/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard r.succeeded else {
            logger.error("ditto couldn't unzip \(zip.path): \(r.errorOutput.suffix(400))")
            throw IconLabError.tool("couldn't unzip \(zip.lastPathComponent) (ditto \(r.status))")
        }
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func megabytes(_ n: Int) -> String {
        n < 1_000_000 ? "\(max(1, n / 1000)) KB" : String(format: "%.0f MB", Double(n) / 1_000_000)
    }
}

/// A loaded Core ML model. `MLModel` isn't marked Sendable, but its predictions are safe from any thread.
nonisolated public struct LoadedModel: @unchecked Sendable {
    public let name: String
    public let model: MLModel
}

/// One file over HTTP into `<dest>.part`, resumed from where an earlier attempt stopped, hashed as it arrives
/// and moved into place only when its size and SHA-256 match.
nonisolated enum FileDownload {
    static func fetch(_ url: URL, to dest: URL, size: Int, sha256 expected: String,
                      progress: @escaping @Sendable (Int) async -> Void) async throws {
        let fm = FileManager.default
        let part = dest.appendingPathExtension("part")
        var have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        if have > size { try? fm.removeItem(at: part); have = 0 }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let sink = try Sink(part: part, have: have, progress: progress)
        if have < size {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("SecondChanceIconLab/0.1 (local tool)", forHTTPHeaderField: "User-Agent")
            if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
            let session = URLSession(configuration: .ephemeral, delegate: sink, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    sink.done = cont
                    session.dataTask(with: req).resume()
                }
            } onCancel: { session.invalidateAndCancel() }
        }
        let (got, count) = sink.finish()
        await progress(count)
        guard count == size, got == expected else {
            try? fm.removeItem(at: part)
            throw IconLabError.tool("\(dest.lastPathComponent) didn't match its checksum (got \(count) bytes, \(got.prefix(12))…)")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    /// Writes and hashes what arrives. URLSession calls it on one serial queue, so the lock only guards `finish`.
    final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let out: FileHandle
        private var hasher = SHA256()
        private var have: Int
        private var failed: Error?
        private var lastReport = Date.distantPast
        private let lock = NSLock()
        private let progress: @Sendable (Int) async -> Void
        var done: CheckedContinuation<Void, Error>?

        init(part: URL, have: Int, progress: @escaping @Sendable (Int) async -> Void) throws {
            self.have = have
            self.progress = progress
            if have > 0 {
                let h = try FileHandle(forReadingFrom: part)
                while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
                try h.close()
            }
            out = try FileHandle(forWritingTo: part)
            try out.seekToEnd()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            lock.lock(); defer { lock.unlock() }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200   // file: URLs, in tests
            if code == 200, have > 0 {
                // the server ignored the Range: start again
                try? out.truncate(atOffset: 0)
                hasher = SHA256()
                have = 0
            } else if code != 200, code != 206 {
                failed = IconLabError.tool("HTTP \(code) for \(response.url?.lastPathComponent ?? "a model file")")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            do { try out.write(contentsOf: data) } catch { failed = error; lock.unlock(); dataTask.cancel(); return }
            hasher.update(data: data)
            have += data.count
            let n = have
            let report = Date().timeIntervalSince(lastReport) > 0.25
            if report { lastReport = Date() }
            lock.unlock()
            if report { let p = progress; Task { await p(n) } }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let e = failed ?? error
            let c = done
            done = nil
            lock.unlock()
            if let e { c?.resume(throwing: e) } else { c?.resume() }
        }

        func finish() -> (String, Int) {
            lock.lock(); defer { lock.unlock() }
            try? out.close()
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), have)
        }
    }
}
