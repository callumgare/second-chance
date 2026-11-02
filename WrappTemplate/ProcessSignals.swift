//
//  ProcessSignals.swift
//  WrappTemplate
//
//  What the wrapp does when it is sent a signal: quit as if from the menu,
//  or capture diagnostics. And the process-wide state that has to outlive
//  `main()`.

import Foundation
import AppKit
import Logging
import os
import SecondChanceKit
import Synchronization
import SecondChanceReporting
import GameCatalog

// MARK: - Termination signals

/// Kept alive for the life of the process.
private var terminationSignalSources: [DispatchSourceSignal] = []

/// Keeps App Nap off for the life of the process (`main`).
var appNapOff: NSObjectProtocol?

/// Kills the game's Wine session, once the configuration is known: called
/// when the wrapp has to exit without its cleanup having finished.
nonisolated let killWineBeforeForcedExit = Mutex<(@Sendable () -> Void)?>(nil)

/// Capture a diagnostics bundle on SIGUSR1, whatever the launch or the game
/// is doing: `kill -USR1 <wrapp pid>`, for a game that seems stuck. See
/// `StartupDiagnostics`.
func installDiagnosticsSignalHandler(_ gameLauncher: GameLauncher) {
    var set = sigset_t()
    sigemptyset(&set)
    sigaddset(&set, SIGUSR1)
    pthread_sigmask(SIG_UNBLOCK, &set, nil)
    signal(SIGUSR1, SIG_IGN)
    // Not on the main queue, which may be what is stuck; so `@Sendable`, as
    // a main-actor handler would trap there.
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .userInitiated))
    source.setEventHandler { @Sendable in
        mainLogger.notice("Received SIGUSR1: capturing diagnostics")
        gameLauncher.captureDiagnostics(.manual)
    }
    source.resume()
    terminationSignalSources.append(source)
}

/// Quit like Cmd-Q on SIGTERM, SIGINT or SIGHUP: end the game and its Wine
/// session and log that it happened, instead of dying silently or (when the
/// signal arrived masked) not at all.
func installTerminationHandlers() {
    // A signal blocked by whoever started us stays blocked across exec;
    // unblock these so they are delivered at all.
    var set = sigset_t()
    sigemptyset(&set)
    for sig in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&set, sig) }
    pthread_sigmask(SIG_UNBLOCK, &set, nil)

    for (sig, code) in [(SIGTERM, Int32(143)), (SIGINT, 130), (SIGHUP, 129)] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            mainLogger.notice("Received \(SubprocessWatch.signalName(sig)): quitting the game")
            // Off the main queue, so it fires even if the main thread is stuck;
            // later on a busy Mac, whose quit gets longer (`quitPeriods`).
            DispatchQueue.global(qos: .userInitiated).async {
                let after = GameLauncher.quitPeriods(announce: false).forcedExitAfter
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + after) {
                    mainLogger.error("Cleanup didn't finish within \(Int(after)) s of \(SubprocessWatch.signalName(sig)); exiting anyway")
                    // Not with Wine still running in the prefix, though.
                    killWineBeforeForcedExit.withLock { $0 }?()
                    LogStore.shared.flush()
                    exit(code)
                }
            }
            // Not called here: this handler is a block on the main queue, and
            // terminate (via .terminateLater) waits in a nested event loop for
            // the cleanup's reply, which is itself queued on the main queue —
            // behind this block. A wrapp quit while Steam waited for a
            // sign-in hung there for good. From the run loop, the main queue
            // keeps draining while terminate waits.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
            }
        }
        source.resume()
        terminationSignalSources.append(source)
    }
}
