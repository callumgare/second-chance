//
//  ChildProcessTests.swift
//  SecondChanceTests
//
//  A child started with runWithoutCrashHandler() doesn't inherit our
//  exception ports. With them, a child's bad memory access goes to whatever
//  holds our port; Sentry's stops listening after two, and a Wine program
//  then hangs at 0% CPU (docs/failure-reports.md#child-processes).

import Darwin
import Foundation
import Testing
@testable import SecondChance

private let python = "/usr/bin/python3"

@Suite("Child processes and our crash handler", .serialized)
struct ChildProcessTests {
    @Test("A child faults normally when started without our crash handler",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python), "needs \(python) to make a child that faults"))
    func childDoesNotInheritExceptionPort() throws {
        try withDeadExceptionPort { _ in
            // The control: a plain run() hands the child our port, so its
            // fault waits for a reply that never comes. Without this the test
            // could pass for a reason that has nothing to do with the ports.
            let inherited = try startFaultingChild { try $0.run() }
            #expect(!exits(inherited, within: 2), "a child given our dead port should hang at its fault")
            kill(inherited.processIdentifier, SIGKILL)
            inherited.waitUntilExit()

            let cleared = try startFaultingChild { try $0.runWithoutCrashHandler() }
            #expect(exits(cleared, within: 10), "the child should fault and exit, not wait on our port")
            #expect(cleared.terminationReason == .uncaughtSignal)
            #expect(cleared.terminationStatus == SIGSEGV)
        }
    }

    @Test("Our own exception port is put back after starting a child")
    func portIsRestored() throws {
        try withDeadExceptionPort { port in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try child.runWithoutCrashHandler()
            child.waitUntilExit()
            #expect(currentBadAccessPort() == port)
        }
    }

    // MARK: - Helpers

    private static let badAccess = exception_mask_t(1) << exception_mask_t(EXC_BAD_ACCESS)

    /// Run `body` with this process's bad-access exception port pointing at a
    /// port nobody reads, as Sentry's is once its handler threads have gone.
    /// Kept short: while it is set, a crash in this test process would hang.
    private func withDeadExceptionPort(_ body: (mach_port_t) throws -> Void) throws {
        let task = mach_task_self_
        let saved = savedBadAccessPort()
        var port = mach_port_t(MACH_PORT_NULL)
        try #require(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS)
        try #require(mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        try #require(task_set_exception_ports(task, Self.badAccess, port, exception_behavior_t(EXCEPTION_DEFAULT),
                                              thread_state_flavor_t(THREAD_STATE_NONE)) == KERN_SUCCESS)
        defer {
            _ = task_set_exception_ports(task, Self.badAccess, saved.port, saved.behavior, saved.flavor)
            if saved.port != mach_port_t(MACH_PORT_NULL) { mach_port_deallocate(task, saved.port) }
            mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1)
        }
        try body(port)
    }

    private func savedBadAccessPort() -> (port: mach_port_t, behavior: exception_behavior_t, flavor: thread_state_flavor_t) {
        var masks = [exception_mask_t](repeating: 0, count: 1)
        var ports = [mach_port_t](repeating: mach_port_t(MACH_PORT_NULL), count: 1)
        var behaviors = [exception_behavior_t](repeating: exception_behavior_t(EXCEPTION_DEFAULT), count: 1)
        var flavors = [thread_state_flavor_t](repeating: thread_state_flavor_t(THREAD_STATE_NONE), count: 1)
        var count = mach_msg_type_number_t(1)
        guard task_get_exception_ports(mach_task_self_, Self.badAccess, &masks, &count, &ports, &behaviors, &flavors) == KERN_SUCCESS,
              count == 1 else {
            return (mach_port_t(MACH_PORT_NULL), exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
        }
        return (ports[0], behaviors[0], flavors[0])
    }

    private func currentBadAccessPort() -> mach_port_t {
        let current = savedBadAccessPort()
        if current.port != mach_port_t(MACH_PORT_NULL) { mach_port_deallocate(mach_task_self_, current.port) }
        return current.port
    }

    /// A child that reads address 0: a real bad access, as a Windows program's
    /// deliberate faults are, rather than a signal sent to it.
    private func startFaultingChild(_ start: (Process) throws -> Void) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-c", "import ctypes; ctypes.string_at(0)"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try start(child)
        return child
    }

    private func exits(_ process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        return !process.isRunning
    }
}
