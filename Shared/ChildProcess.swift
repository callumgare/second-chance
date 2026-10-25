//
//  ChildProcess.swift
//  Shared
//
//  Start a child process without handing it our crash handler.
//
//  A child inherits its parent's task exception ports. With failure reporting
//  on, Sentry points ours at its Mach exception handler, so a child's every
//  bad memory access is sent to Sentry inside this process rather than
//  turning into a signal in the child. Windows programs fault on purpose all
//  the time and Wine relies on that signal, so a Wine program started with our
//  ports hangs at its third fault: Sentry answers one fault on each of its two
//  handler threads, files each as a crash of ours, and then nobody is left to
//  answer, so the faulting thread waits in the kernel for ever
//  (docs/failure-reports.md#child-processes).

import Darwin
import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.ChildProcess")

extension Process {
    /// `run()`, with this process's exception ports cleared for the child.
    /// Use it for Wine, and for anything that starts Wine (a shell, winetricks):
    /// the cleared ports pass down to the child's own children.
    nonisolated func runWithoutCrashHandler() throws {
        try InheritedExceptionPorts.withoutOurs { try run() }
    }
}

nonisolated enum InheritedExceptionPorts {
    /// Held while the ports are cleared, so two launches can't save each
    /// other's cleared ports and leave them cleared for good.
    private static let lock = NSLock()

    /// Run `body` (which starts a child) with this task's exception ports
    /// cleared, then put them back. A crash on another thread in that moment
    /// still reaches Sentry's signal handler; only its Mach handler misses it.
    static func withoutOurs<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }

        let task = mach_task_self_
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: mach_port_t(MACH_PORT_NULL), count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)
        // Every exception type (1 through EXC_TYPES_COUNT - 1), as EXC_MASK_ALL.
        let allMasks = (1..<EXC_TYPES_COUNT).reduce(exception_mask_t(0)) { $0 | (exception_mask_t(1) << exception_mask_t($1)) }
        let read = task_get_exception_ports(task, allMasks, &masks, &count, &ports, &behaviors, &flavors)
        guard read == KERN_SUCCESS else {
            logger.warning("Couldn't read our exception ports (\(read)); starting the child with them")
            return try body()
        }
        let saved = (0..<Int(count)).filter { ports[$0] != mach_port_t(MACH_PORT_NULL) }
        guard !saved.isEmpty else { return try body() }

        for index in saved {
            let cleared = task_set_exception_ports(task, masks[index], mach_port_t(MACH_PORT_NULL),
                                                   exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
            if cleared != KERN_SUCCESS {
                logger.warning("Couldn't clear exception port for mask \(masks[index]) (\(cleared)); the child may inherit it")
            }
        }
        defer {
            for index in saved {
                let restored = task_set_exception_ports(task, masks[index], ports[index], behaviors[index], flavors[index])
                if restored != KERN_SUCCESS {
                    logger.error("Couldn't restore exception port for mask \(masks[index]) (\(restored)); crashes may go unreported")
                }
                mach_port_deallocate(task, ports[index])
            }
        }
        return try body()
    }
}
