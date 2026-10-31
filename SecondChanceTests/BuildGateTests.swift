//
//  BuildGateTests.swift
//  SecondChanceTests
//
//  The integration tests' build gate: how many builds it lets in at once,
//  and how much disk it lets them take.
//

import Foundation
import Synchronization
import Testing
@testable import SecondChance

@Suite("Integration build gate")
struct BuildGateTests {
    private static let gigabyte: Int64 = 1_000_000_000

    /// A gate on a disk with `free` GB free, which a test can change.
    private final class Disk: Sendable {
        let free: Mutex<Int64>
        init(free: Int64) { self.free = Mutex(free * BuildGateTests.gigabyte) }
    }

    private func gate(slots: Int, freeGB: Int64, marginGB: Int64 = 1) -> (BuildGate, Disk) {
        let disk = Disk(free: freeGB)
        let gate = BuildGate(slots: slots, margin: marginGB * Self.gigabyte, recheckInterval: .milliseconds(20)) {
            disk.free.withLock { $0 }
        }
        return (gate, disk)
    }

    /// A build asking the gate, in a task of its own.
    private final class Request: Sendable {
        let letIn = Mutex(false)
    }

    private func ask(_ gate: BuildGate, gb: Int64) -> Request {
        let request = Request()
        Task {
            _ = try? await gate.admit(bytes: gb * Self.gigabyte)
            request.letIn.withLock { $0 = true }
        }
        return request
    }

    /// Whether the build is let in within `seconds`: briefly, to see it held
    /// back, and longer to see it let in, since the unit tests run side by
    /// side and a busy Mac can be slow to get to it.
    private func isLetIn(_ request: Request, within seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !request.letIn.withLock({ $0 }) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func isHeldBack(_ request: Request) async -> Bool {
        await !isLetIn(request, within: 0.2)
    }

    @Test("No more builds than slots at once; a finished build frees its slot")
    func slots() async throws {
        let (gate, _) = gate(slots: 2, freeGB: 100)
        let first = try await gate.admit(bytes: Self.gigabyte)
        _ = try await gate.admit(bytes: Self.gigabyte)
        let third = ask(gate, gb: 1)
        #expect(await isHeldBack(third))
        await gate.finishedBuilding(first)
        #expect(await isLetIn(third))
    }

    @Test("Builds don't reserve more disk than was free, less the margin; space comes back once a build's output is gone")
    func diskBudget() async throws {
        let (gate, _) = gate(slots: 4, freeGB: 21)
        let first = try await gate.admit(bytes: 10 * Self.gigabyte)
        _ = try await gate.admit(bytes: 10 * Self.gigabyte)
        let third = ask(gate, gb: 10)
        #expect(await isHeldBack(third))
        // Built, but its wrapp waits for its launch: still holding its space.
        await gate.finishedBuilding(first)
        #expect(await isHeldBack(third))
        await gate.release(first)
        #expect(await isLetIn(third))
    }

    @Test("Space something else takes meanwhile holds builds back")
    func spaceTakenMeanwhile() async throws {
        let (gate, disk) = gate(slots: 4, freeGB: 100)
        let first = try await gate.admit(bytes: 10 * Self.gigabyte)
        await gate.noteUse(first, bytes: 10 * Self.gigabyte)
        disk.free.withLock { $0 = 15 * Self.gigabyte }
        let second = ask(gate, gb: 20)
        #expect(await isHeldBack(second))
        disk.free.withLock { $0 = 50 * Self.gigabyte }
        #expect(await isLetIn(second))
    }

    @Test("A build is let in when nothing else is under way, unless the disk can't hold it at all")
    func aloneOnTheDisk() async throws {
        let (gate, _) = gate(slots: 2, freeGB: 9)
        // Over the budget (8 GB), but within what's free once its quarter's
        // padding is taken off.
        let ticket = try await gate.admit(bytes: 10 * Self.gigabyte)
        await gate.release(ticket)
        await #expect(throws: BuildGate.NoRoom.self) {
            _ = try await gate.admit(bytes: 20 * Self.gigabyte)
        }
    }

    @Test("First come, first served: a small build doesn't jump a large one")
    func firstComeFirstServed() async throws {
        let (gate, _) = gate(slots: 4, freeGB: 21)
        let first = try await gate.admit(bytes: 15 * Self.gigabyte)
        let large = ask(gate, gb: 15)
        try await Task.sleep(for: .milliseconds(20))
        let small = ask(gate, gb: 1)
        #expect(await isHeldBack(small))
        await gate.release(first)
        #expect(await isLetIn(large))
        #expect(await isLetIn(small))
    }
}
