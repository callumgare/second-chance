//
//  WineDesktop.swift
//  Shared
//
//  Wine's desktop, started ahead of the Windows programs that need it.

import Foundation
import Logging

/// Wine's desktop (`explorer.exe /desktop`), started and waited for before a
/// Windows program runs.
///
/// Left to Wine, a program's first desktop access starts the desktop and gives
/// it 10 seconds; on a loaded machine under Rosetta that runs out, and the
/// program carries on with no display adapters ("The explorer process failed
/// to start"). A game then crashes, and an installer or patcher exits non-zero.
/// Here the wait is up to `timeout` — three minutes by default, since on a
/// heavily loaded machine (load average 40+) the desktop has taken over a
/// minute, and a program run without it is sure to fail — and if the desktop
/// is never ready the program runs anyway, as it would have.
///
/// Wine runs the desktop through `start.exe /exec`, which is itself a Windows
/// program waiting for explorer, while explorer only exits once no programs are
/// left — so the two keep each other, and the whole Wine session, alive.
/// `release()` ends `start.exe` once the programs are done; explorer then
/// closes normally. Call it before `wineserver -w`, which would otherwise wait
/// for ever.
public final class WineDesktop {
    private let launcher: Process
    private let logger: Logger

    private init(launcher: Process, logger: Logger) {
        self.launcher = launcher
        self.logger = logger
    }

    /// Start the desktop and wait until it has registered the display devices.
    /// Nil when it was already running, or could not be started — in both
    /// cases there is nothing to release. Blocks: each check runs `reg.exe`.
    public static func start(
        _ wine: WineEnvironment,
        timeout: TimeInterval = 180,
        logger: Logger,
        outputLogger: Logger
    ) -> WineDesktop? {
        let start = Date()
        if wine.displayDevicesRegistered() {
            logger.notice("[Desktop] Already running (checked in \(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
            return nil
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let launcher: Process
        do {
            launcher = try wine.startDesktop(outputPipe: outputPipe, errorPipe: errorPipe)
        } catch {
            logger.warning("[Desktop] Could not start the desktop, leaving it to Wine: \(error)")
            return nil
        }
        ProcessLineLogger.attach(to: outputPipe, logger: outputLogger, level: .notice)
        ProcessLineLogger.attach(to: errorPipe, logger: outputLogger, level: .warning)
        logger.notice("[Desktop] Started explorer.exe /desktop (launcher PID \(launcher.processIdentifier)), waiting for display devices...")
        let desktop = WineDesktop(launcher: launcher, logger: logger)

        let deadline = start.addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let queryStart = Date()
            let result = wine.queryDisplayDevices()
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            if result == .registered {
                logger.notice("[Desktop] Ready after \(elapsed)s (\(attempt) checks)")
                return desktop
            }
            logger.debug("[Desktop] Check \(attempt): \(result) (query took \(String(format: "%.1f", Date().timeIntervalSince(queryStart)))s, \(elapsed)s since start)")
            Thread.sleep(forTimeInterval: 0.25)
        }
        logger.error("[Desktop] Display devices still not registered after \(Int(timeout))s — running the program anyway")
        return desktop
    }

    /// Let the desktop shut down once the programs that needed it are done.
    /// Safe to call more than once.
    public func release() {
        guard launcher.isRunning else { return }
        logger.notice("[Desktop] Releasing the desktop launcher (PID \(launcher.processIdentifier))")
        launcher.terminate()
    }
}
