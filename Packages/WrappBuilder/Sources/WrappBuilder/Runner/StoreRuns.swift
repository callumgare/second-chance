//
//  StoreRuns.swift
//  WrappBuilder
//
//  A build's use of its stores: each one's folder, its declaration recorded
//  beside it, and its lock held while a step uses it (decision 23 of the
//  builders plan; docs/wrappfile.md#stores).

import Foundation
import Logging
import Synchronization
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Stores")

/// Where a build's stores are, and whose they are: what the runner needs to
/// find one's folder and lock.
public nonisolated struct StoreSettings: Sendable {
    public var locations: StoreLocations
    /// The app the build is for, whose `app` stores it uses.
    public var appID: String
    /// What a lock's file says holds it while this build does: the app's name.
    public var holder: String
    /// How long a build waits for a lock someone else holds before it
    /// fails, saying who: `SECOND_CHANCE_LOCK_WAIT` seconds, 30 minutes by
    /// default.
    public var lockWait: Duration

    public init(locations: StoreLocations, appID: String, holder: String,
                lockWait: Duration = Self.lockWait()) {
        self.locations = locations
        self.appID = appID
        self.holder = holder
        self.lockWait = lockWait
    }

    public static func lockWait(environment: [String: String] = ProcessInfo.processInfo.environment) -> Duration {
        environment["SECOND_CHANCE_LOCK_WAIT"].flatMap(Double.init).map { .seconds($0) } ?? .seconds(30 * 60)
    }
}

nonisolated enum StoreRuns {
    /// A store's folder, made if it isn't there, with its declaration
    /// recorded beside it (`store.json`) the first time and checked every
    /// time after: a declaration that disagrees with the store's is a
    /// recipe problem naming both.
    static func folder(of store: StoreDeclaration, settings: StoreSettings, origin: String) throws -> URL {
        let folder = settings.locations.folder(owner: store.owner, name: store.name, retention: store.retention.rawValue,
                                               global: store.scope == .global, appID: settings.appID)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = folder.deletingLastPathComponent().appendingPathComponent("\(store.name).store.json")
        let declared = StoreRecord(retention: store.retention.rawValue, scope: store.scope.rawValue, lock: store.lock)
        if let data = files.contents(atPath: record.path), let recorded = try? JSONDecoder().decode(StoreRecord.self, from: data) {
            guard recorded == declared else {
                throw StepFailure.recipe("\(origin): \(store.fullName) is declared \(declared), but the store was made \(recorded). "
                    + "A store that changes gets a new name, or the old one is removed (sc store remove \(store.fullName))")
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(declared).write(to: record, options: .atomic)
        }
        return folder
    }

    /// What's recorded with a store.
    struct StoreRecord: Codable, Equatable, CustomStringConvertible {
        var retention: String
        var scope: String
        var lock: String?

        var description: String { "--retention=\(retention) --scope=\(scope)\(lock.map { " --exclusive=\($0)" } ?? "")" }
    }
}

/// A store's lock, held for a build (`ProcessLocks`): a step of the build
/// that holds it already shares it, another build or app waits.
nonisolated final class StoreLock: Sendable {
    let name: String
    let file: URL
    let token: UUID

    private init(name: String, file: URL, token: UUID) {
        self.name = name
        self.file = file
        self.token = token
    }

    /// `lock`, taken for the build `token` is: at once if it's free or the
    /// build has it, else after waiting, emitting `lockWaiting` and then
    /// `lockAcquired`. Fails once `settings.lockWait` has passed.
    static func take(_ lock: LockDeclaration, token: UUID, settings: StoreSettings, emitter: any EventEmitter,
                     origin: String) async throws -> StoreLock {
        let file = settings.locations.lockFile(owner: lock.owner, name: lock.name, global: lock.scope == .global, appID: settings.appID)
        let started = ContinuousClock.now
        var waiting = false
        while true {
            try Task.checkCancellation()
            if try ProcessLocks.tryTake(file, token: token, holder: settings.holder) {
                if waiting {
                    let seconds = (ContinuousClock.now - started) / .seconds(1)
                    logger.notice("Got the \(lock.fullName) lock after \(Int(seconds))s")
                    emitter.emit(.lockAcquired(lock: lock.fullName, seconds: seconds))
                }
                return StoreLock(name: lock.fullName, file: file, token: token)
            }
            let found = ProcessLocks.holder(of: file)
            let holder = found.name.map { name in "\(name)\(found.pid.map { " (pid \($0))" } ?? "")" } ?? found.pid.map { "pid \($0)" }
            if !waiting {
                waiting = true
                logger.notice("Waiting for the \(lock.fullName) lock, held by \(holder ?? "something else")")
                emitter.emit(.lockWaiting(lock: lock.fullName, holder: holder))
            }
            if ContinuousClock.now - started > settings.lockWait {
                throw StepFailure.failed("\(origin): the \(lock.fullName) lock was still held by \(holder ?? "something else") "
                    + "after \(settings.lockWait)")
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    func release() { ProcessLocks.release(file, token: token) }
}

/// What a step holds of its stores until it ends: their locks.
nonisolated final class StoreHolds: Sendable {
    private let locks = Mutex<[StoreLock]>([])

    func add(_ lock: StoreLock) { locks.withLock { $0.append(lock) } }

    func releaseAll() {
        let all = locks.withLock { locks in defer { locks = [] }; return locks }
        for lock in all.reversed() { lock.release() }
    }
}
