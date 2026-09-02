//
//  AppLogging.swift
//  Shared
//
//  Bootstrap function to configure swift-log with our multiplex handler.
//
//  LoggingSystem.bootstrap is once-only per process (a second call is a
//  precondition failure), so this performs exactly one bootstrap and is
//  idempotent afterwards. A second call with a *different* subsystem records
//  a fault rather than being silently swallowed.

import Foundation
import os
import Logging

nonisolated enum AppLogging {

    private static let lock = NSLock()
    private static var bootstrapped = false
    private static var completedBootstrap = false
    private static var subsystemUsed: String?

    /// Bootstrap the logging system. Must be the first executable statement of
    /// the process — a Logger constructed before this call is permanently
    /// bound to swift-log's default StreamLogHandler and never reaches
    /// LogStore, the log window, or the export.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem for this process (e.g. "au.gare.callum.second-chance.SecondChance")
    ///   - fileNamePrefix: Prefix for generated files (currently unused, kept for API stability)
    nonisolated static func bootstrap(subsystem: String, fileNamePrefix: String = "") {
        lock.lock()
        defer { lock.unlock() }

        guard !bootstrapped else {
            if let existing = subsystemUsed, existing != subsystem {
                // Programming error: two different subsystems in one process.
                // Record a fault where it will survive even a crash.
                os_log("AppLogging.bootstrap called again with different subsystem: %{public}@ vs %{public}@",
                       log: .default, type: .fault, existing, subsystem)
            }
            return
        }
        bootstrapped = true
        subsystemUsed = subsystem

        LoggingSystem.bootstrap { label in
            #if DEBUG
            // Tripwire: the factory runs for every Logger construction. If one
            // happens while bootstrap() is still on the stack, logging state
            // (e.g. the disk mirror) may not be configured yet — loud in debug.
            if !completedBootstrap {
                assertionFailure("Logger created before AppLogging.bootstrap() completed! Label: \(label)")
            }
            #endif
            return MultiplexLogHandler(label: label)
        }

        // Check for --mirror-logs flag (WrappTemplate and GamePuppeteer have no settings UI).
        if CommandLine.arguments.contains("--mirror-logs") {
            LogStore.shared.setDiskMirror(enabled: true)
        }

        completedBootstrap = true
    }

    /// Whether bootstrap() has fully returned. Call sites that construct
    /// loggers very early can assert this in debug builds.
    nonisolated static var isBootstrapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completedBootstrap
    }
}
