//
//  CLIBuilder.swift
//  SecondChance
//
//  Headless (non-interactive) build driver. Validates the environment,
//  starts the requested build on the app's WrappBuildViewModel, as the
//  welcome screen would, and terminates the process with the right exit
//  code. The window stays hidden unless SECOND_CHANCE_SHOW_UI=1, which shows
//  it going through the screens a person would see.
//
//  The exits live here, not in WrappBuildViewModel, so the ViewModel is safe
//  to instantiate in tests regardless of environment variables — no code
//  path in the ViewModel terminates the process.
//
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
import SecondChanceKit

enum CLIBuilder {
    private nonisolated static let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.CLIBuilder")

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// True when the process was launched to run headless (`NON_INTERACTIVE=true`).
    static var isEnabled: Bool {
        environment["NON_INTERACTIVE"] == "true"
    }

    /// Whether a headless run shows its window (`SECOND_CHANCE_SHOW_UI=1`),
    /// for watching the build. It still asks nothing: every answer comes
    /// from the environment, as without the window.
    static var showsUI: Bool {
        environment["SECOND_CHANCE_SHOW_UI"] == "1"
    }

    /// Validate the headless environment synchronously.
    ///
    /// Exits the process (code 1) with a logged reason when required
    /// variables are missing or invalid — call this before the UI starts so
    /// misconfigured runs fail fast. Returns the validated source on success.
    static func validatedSource() -> WrappSource {
        guard let name = environment["INSTALLATION_SOURCE"] else {
            failValidation("INSTALLATION_SOURCE environment variable is required (disk, her-download, steam, big-fish, download)")
        }

        guard let source = WrappSource(rawValue: name) else {
            failValidation("Invalid INSTALLATION_SOURCE '\(name)' (disk, her-download, steam, big-fish, download)")
        }

        logger.notice("NON-INTERACTIVE MODE: Auto-starting installation — source: \(name)")

        if source == .disk {
            guard let disk1 = environment["DISK_1_PATH"] else {
                failValidation("DISK_1_PATH environment variable is required for disk installation")
            }
            logger.notice("Disk 1: \(disk1)")
            if let disk2 = environment["DISK_2_PATH"] {
                logger.notice("Disk 2: \(disk2)")
            }
        }

        if source == .herDownload {
            guard let download = environment["HER_INSTALLER_PATH"] else {
                failValidation("HER_INSTALLER_PATH environment variable is required for a Her download (the .exe or .dmg)")
            }
            logger.notice("Her download: \(download)")
        }

        if source == .bigFish {
            guard let slug = environment["BIG_FISH_GAME_SLUG"] else {
                failValidation("BIG_FISH_GAME_SLUG environment variable is required for a Big Fish build (the game's slug)")
            }
            logger.notice("Big Fish game: \(slug)\(environment["BIG_FISH_TRIAL"] == "1" ? " (free trial)" : "")")
        }

        if source == .download {
            guard let program = environment["DOWNLOAD_PROGRAM"] else {
                failValidation("DOWNLOAD_PROGRAM environment variable is required for a download (a bundle id, freeware/skifree)")
            }
            logger.notice("Download: \(program)")
        }

        guard let output = environment["OUTPUT_PATH"] else {
            failValidation("OUTPUT_PATH environment variable is required (directory where .app will be saved)")
        }
        logger.notice("Output: \(output)")

        // The paths themselves are validated by WrappBuildInput when read.
        return source
    }

    /// Run the build for a validated source through the app's view model,
    /// then terminate the process. Never returns.
    ///
    /// The view model is the window's, so a run with `SECOND_CHANCE_SHOW_UI=1`
    /// shows the screens a person building that game would see.
    static func run(source: WrappSource, viewModel: WrappBuildViewModel) async -> Never {
        // Machine-readable progress for whoever started the build (sc wrapp
        // build). Kept alive for the rest of the process, which ends below.
        if let progress = ProgressFileWriter.fromEnvironment("SECOND_CHANCE_PROGRESS_PATH") {
            await progress.subscribe(to: viewModel.bus)
        }

        viewModel.selectedWrappSource = source
        await viewModel.build(from: source)

        guard viewModel.builtWrappURL != nil else {
            exitWithFailure(viewModel.lastBuildError ?? WrappBuildError.internalError("The build ended without an app or an error"))
        }
        logger.notice("NON-INTERACTIVE MODE: Exiting with success")
        fflush(stdout)
        AutomationBridge.shared.stop()
        LogStore.shared.flush()
        _exit(0)
    }

    /// Log, flush, and terminate with a failure exit code. Never returns.
    private static func exitWithFailure(_ error: Error) -> Never {
        // The view model has already logged the failure's summary.
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
