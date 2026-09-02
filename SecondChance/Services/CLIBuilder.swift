//
//  CLIBuilder.swift
//  SecondChance
//
//  Headless (non-interactive) build driver. Validates the environment,
//  runs the requested build, and terminates the process with the right
//  exit code.
//
//  Extracted from WrappBuildViewModel so the ViewModel is pure UI state
//  and safe to instantiate in tests regardless of environment variables.
//  The exit sequencing is deliberate and must be preserved:
//
//  - validation failure → log, flush stdout/stderr, flush LogStore, exit(1)
//    (exit(1) — not _exit — so atexit handlers run)
//  - build success      → fflush(stdout), stop the automation bridge, flush
//    LogStore, _exit(0)
//  - build failure      → fflush(stdout) + fflush(stderr), flush LogStore,
//    _exit(1)
//
//  LogStore is flushed on every path: without it the last log lines are
//  lost when the process dies via _exit (mirrors the signal handlers).
//

import Foundation
import Logging

enum CLIBuilder {
    private nonisolated static let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.CLIBuilder")

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// True when the process was launched to run headless (`NON_INTERACTIVE=true`).
    static var isEnabled: Bool {
        environment["NON_INTERACTIVE"] == "true"
    }

    /// Validate the headless environment synchronously.
    ///
    /// Exits the process (code 1) with a logged reason when required
    /// variables are missing or invalid — call this before the UI starts so
    /// misconfigured runs fail fast. Returns the validated source on success.
    static func validatedSource() -> String {
        guard let source = environment["INSTALLATION_SOURCE"] else {
            failValidation("INSTALLATION_SOURCE environment variable is required (disk, her-download, steam)")
        }

        guard source == "disk" || source == "her-download" || source == "steam" else {
            failValidation("Invalid INSTALLATION_SOURCE '\(source)' (disk, her-download, steam)")
        }

        logger.notice("NON-INTERACTIVE MODE: Auto-starting installation — source: \(source)")

        if source == "disk" {
            guard let disk1 = environment["DISK_1_PATH"] else {
                failValidation("DISK_1_PATH environment variable is required for disk installation")
            }
            logger.notice("Disk 1: \(disk1)")
            if let disk2 = environment["DISK_2_PATH"] {
                logger.notice("Disk 2: \(disk2)")
            }
        }

        guard let output = environment["OUTPUT_PATH"] else {
            failValidation("OUTPUT_PATH environment variable is required (directory where .app will be saved)")
        }
        logger.notice("Output: \(output)")

        // The paths themselves are validated by WrappBuildInput when read.
        return source
    }

    /// Run the build for a validated source, then terminate the process.
    /// Never returns.
    static func run(source: String) async -> Never {
        let builder: WrappBuildStrategy
        switch source {
        case "disk":
            builder = DiskWrappBuilder()
        case "her-download":
            builder = HerDownloadWrappBuilder()
        case "steam":
            builder = SteamWrappBuilder()
        default:
            logger.critical("NON-INTERACTIVE MODE: Unknown installation source '\(source)'")
            exitWithFailure(WrappBuildError.internalError("Unknown installation source '\(source)'"))
        }

        let input = WrappBuildInput(viewModel: nil)

        do {
            _ = try await builder.build(input: input)

            logger.notice("NON-INTERACTIVE MODE: Exiting with success")
            fflush(stdout)
            AutomationBridge.shared.stop()
            LogStore.shared.flush()
            _exit(0)
        } catch {
            exitWithFailure(error)
        }
    }

    /// Log, flush, and terminate with a failure exit code. Never returns.
    private static func exitWithFailure(_ error: Error) -> Never {
        logger.critical("NON-INTERACTIVE MODE: Exiting with error — \(error.localizedDescription)")
        fflush(stdout)
        fflush(stderr)
        LogStore.shared.flush()
        _exit(1)
    }

    /// Log a validation failure and terminate with a non-zero exit.
    private static func failValidation(_ message: String) -> Never {
        logger.critical("NON-INTERACTIVE MODE: \(message)")
        fflush(stdout)
        fflush(stderr)
        LogStore.shared.flush()
        exit(1)
    }
}
