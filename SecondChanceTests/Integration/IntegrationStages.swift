//
//  IntegrationStages.swift
//  SecondChanceTests
//
//  What lets the integration tests build several games at once while
//  launching them one at a time: a gate on the builds, which holds back a
//  build until the Mac has a slot for it and the disk has room for it, and a
//  lock on the launches, since a game runs full screen and must be in front.

import Foundation
@testable import SecondChance
@testable import SecondChanceKit

enum IntegrationStages {
    /// Builds at once (`sc test integration --build-concurrency`), and the
    /// disk to leave free (`--disk-margin`), in GB.
    static let build = BuildGate(
        slots: max(1, Int(ProcessInfo.processInfo.environment["BUILD_CONCURRENCY"] ?? "") ?? 1),
        margin: Int64((Double(ProcessInfo.processInfo.environment["DISK_MARGIN_GB"] ?? "") ?? 10) * 1_000_000_000)
    )

    /// One game on screen at a time: two wrapps in front confuse
    /// WrappPuppeteer, and only one can be.
    static let launch = AsyncMutex()

    /// One Steam game at a time, built and launched: a wrapp holds Steam's
    /// one-at-a-time lock while it runs Steam, and a build signing in to Steam
    /// while another wrapp holds it fails with `steamInUse`.
    static let steam = AsyncMutex()

    // MARK: - How much disk a build takes

    /// What each game's build took at most in earlier runs, by `source/label`
    /// (`sc`'s `test-results/integration-sizes.json`).
    static let measuredSizes: [String: Int64] = {
        guard let path = ProcessInfo.processInfo.environment["SIZE_ESTIMATES_PATH"],
              let data = FileManager.default.contents(atPath: path),
              let sizes = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return sizes
    }()

    /// The engine every wrapp carries: the template it's copied from.
    static let engineBytes: Int64 = {
        guard let template = Bundle.main.url(forResource: "WrappTemplate", withExtension: "app") else { return 2_000_000_000 }
        return DirectorySize.measure(template, within: template).bytes
    }()

    /// How much disk to reserve for a game's build: a quarter more than it
    /// took before, or before it has been measured, the engine and four times
    /// its installers (White Wolf: 0.9 GB of disc images made a 3.5 GB wrapp),
    /// or for a Steam game, whose download isn't known beforehand, 8 GB.
    static func reservation(source: String, label: String, installers: [URL]) -> Int64 {
        if let measured = measuredSizes["\(source)/\(label)"] {
            return measured + measured / 4
        }
        guard !installers.isEmpty else { return 8_000_000_000 }
        let installerBytes = installers.reduce(Int64(0)) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        }
        let estimate = engineBytes + 4 * installerBytes
        return estimate + estimate / 4
    }
}

/// Holds a build back until a slot is free and the disk has room for it.
///
/// A build takes a slot while it builds and keeps its disk reservation until
/// its output is deleted, after its launch: wrapps waiting for their turn on
/// screen still hold their space, which holds back new builds when launches
/// fall behind. Builds are let in first come, first served. A build is always
/// let in when nothing else is under way, so a run never does worse than one
/// at a time; but if even then the disk can't hold it, it fails at once
/// rather than partway through.
actor BuildGate {
    struct Ticket: Hashable, Sendable {
        let id: UUID
    }

    struct NoRoom: Error, CustomStringConvertible {
        let needed: Int64
        let free: Int64
        var description: String {
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Not enough free disk to build this game: it needs about \(format(needed)), and \(format(free)) is free"
        }
    }

    private struct Holder {
        var reserved: Int64
        var used: Int64 = 0
        var building = true
    }

    private struct Waiter {
        let id: UUID
        let bytes: Int64
        let continuation: CheckedContinuation<Ticket, Error>
    }

    let slots: Int
    /// Disk always left free.
    let margin: Int64
    private let freeSpace: @Sendable () -> Int64?
    private let recheckInterval: Duration
    /// What the builds may reserve between them: the disk free when the first
    /// asked, less the margin. Space others take meanwhile is caught by
    /// looking at what's free now as well.
    private var budget: Int64?
    private var holders: [UUID: Holder] = [:]
    private var queue: [Waiter] = []
    private var rechecking = false

    init(
        slots: Int,
        margin: Int64,
        recheckInterval: Duration = .seconds(30),
        freeSpace: @escaping @Sendable () -> Int64? = BuildGate.freeSpaceInTemporaryDirectory
    ) {
        self.slots = slots
        self.margin = margin
        self.recheckInterval = recheckInterval
        self.freeSpace = freeSpace
    }

    /// Wait for a slot and room for `bytes`. Throws `NoRoom` when nothing
    /// else is under way and the disk still can't hold it.
    func admit(bytes: Int64) async throws -> Ticket {
        if budget == nil { budget = (freeSpace() ?? .max / 2) - margin }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Waiter(id: id, bytes: bytes, continuation: continuation))
            letIn()
        }
    }

    /// The build is over: its slot is free, its reservation still held.
    func finishedBuilding(_ ticket: Ticket) {
        holders[ticket.id]?.building = false
        letIn()
    }

    /// What the build has on disk now, so the room still to come from its
    /// reservation is known.
    func noteUse(_ ticket: Ticket, bytes: Int64) {
        holders[ticket.id]?.used = bytes
    }

    /// Its output is gone: the reservation, and the slot if still held, are free.
    func release(_ ticket: Ticket) {
        holders[ticket.id] = nil
        letIn()
    }

    /// Let in whoever's first in the queue, for as long as there's room.
    private func letIn() {
        while let next = queue.first {
            guard holders.values.filter(\.building).count < slots else { break }
            let free = freeSpace()
            if holders.isEmpty {
                // Its estimate has a quarter on top; fail only if the disk
                // can't take the build as it was measured.
                if let free, free < next.bytes * 4 / 5 {
                    queue.removeFirst()
                    next.continuation.resume(throwing: NoRoom(needed: next.bytes, free: free))
                    continue
                }
            } else {
                let reserved = holders.values.reduce(Int64(0)) { $0 + $1.reserved }
                let toCome = holders.values.reduce(Int64(0)) { $0 + max(0, $1.reserved - $1.used) }
                guard reserved + next.bytes <= (budget ?? .max),
                      free.map({ $0 - toCome >= next.bytes + margin }) ?? true else {
                    scheduleRecheck()
                    break
                }
            }
            queue.removeFirst()
            holders[next.id] = Holder(reserved: next.bytes)
            next.continuation.resume(returning: Ticket(id: next.id))
        }
    }

    /// While a build waits for room, look again now and then: something
    /// other than a build finishing can free space.
    private func scheduleRecheck() {
        guard !rechecking else { return }
        rechecking = true
        Task {
            try? await Task.sleep(for: recheckInterval)
            self.recheck()
        }
    }

    private func recheck() {
        rechecking = false
        letIn()
    }

    /// Free space on the volume builds use: their temp wrapps and output go
    /// in the temporary directory.
    static let freeSpaceInTemporaryDirectory: @Sendable () -> Int64? = {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
