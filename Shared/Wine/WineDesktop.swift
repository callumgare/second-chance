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
/// Here the wait is up to `timeout` — ten minutes by default, and no limit for
/// a wrapp's game, whose loading window says meanwhile whether it looks stuck:
/// with every core busy, a fresh Wine session has taken two and a half minutes
/// to bring its desktop up, and a program run without it is sure to fail. A
/// desktop that is ready ends the wait at once, so this only costs time when
/// something is wrong. A desktop whose launcher has exited won't come up, and
/// one that is never ready doesn't stop the program: it runs anyway, as it
/// would have.
///
/// Wine runs the desktop through `start.exe /exec`, which is itself a Windows
/// program waiting for explorer, while explorer only exits once no programs are
/// left — so the two keep each other, and the whole Wine session, alive.
/// `release()` ends `start.exe` once the programs are done; explorer then
/// closes normally. Call it before `wineserver -w`, which would otherwise wait
/// for ever.
nonisolated public final class WineDesktop: Sendable {
    private let launcher: WineProcess
    private let logger: Logger

    private init(launcher: WineProcess, logger: Logger) {
        self.launcher = launcher
        self.logger = logger
    }

    /// Start the desktop and wait until it has registered the display devices.
    /// Nil when it was already running, or could not be started — in both
    /// cases there is nothing to release. Cancelling the task ends the wait,
    /// leaving the desktop starting.
    public static func start(
        _ wine: Wine,
        timeout: TimeInterval = 600,
        logger: Logger,
        outputLogger: Logger
    ) async -> WineDesktop? {
        let start = Date()
        if await queryDisplayDevices(wine, timeout: 20) == .registered {
            logger.notice("[Desktop] Already running (checked in \(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
            return nil
        }

        let launcher: WineProcess
        do {
            launcher = try wine.start(.wine(["explorer.exe", "/desktop"]), output: .log(outputLogger))
        } catch {
            logger.warning("[Desktop] Could not start the desktop, leaving it to Wine: \(error)")
            return nil
        }
        logger.notice("[Desktop] Started explorer.exe /desktop (launcher PID \(launcher.pid)), waiting for display devices...")
        let desktop = WineDesktop(launcher: launcher, logger: logger)

        let deadline = start.addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline, !Task.isCancelled {
            attempt += 1
            let queryStart = Date()
            // Each check is a Wine program of its own, which on a loaded
            // machine has taken over 30 seconds; cut short, no check would
            // ever see the desktop ready.
            let launcherRunning = launcher.isRunning
            let result = await queryDisplayDevices(wine, timeout: 120)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            if result == .registered {
                logger.notice("[Desktop] Ready after \(elapsed)s (\(attempt) checks)")
                return desktop
            }
            // Checked before the query, so a desktop that came up and
            // registered the devices as its launcher exited isn't missed.
            // The launcher also exits when an explorer Wine started by itself
            // already has the desktop, which may yet come up.
            if !launcherRunning, !ProcessName.isRunning("explorer.exe") {
                let why = "its launcher exited \(launcher.process.terminationStatus) after \(elapsed)s without the display devices registered"
                logger.error("[Desktop] The desktop didn't start: \(why). Running the program anyway")
                return nil
            }
            logger.debug("[Desktop] Check \(attempt): \(result) (query took \(String(format: "%.1f", Date().timeIntervalSince(queryStart)))s, \(elapsed)s since start)")
            // Back off as the wait grows: each check starts a whole Wine
            // process, which on a machine short of CPU competes with the
            // desktop it is waiting for. A tenth of the time waited so far,
            // between a quarter of a second and ten seconds.
            try? await Task.sleep(for: .seconds(min(10, max(0.25, Date().timeIntervalSince(start) / 10))))
        }
        if Task.isCancelled {
            logger.notice("[Desktop] Stopped waiting for the display devices: cancelled")
            return desktop
        }
        let load = SystemLoad.read().map(\.summary) ?? "unknown (ps failed)"
        logger.error("[Desktop] Display devices still not registered after \(String(format: "%.0f", timeout))s — running the program anyway (load: \(load))")
        return desktop
    }

    /// Let the desktop shut down once the programs that needed it are done.
    /// Safe to call more than once.
    public func release() {
        guard launcher.isRunning else { return }
        logger.notice("[Desktop] Releasing the desktop launcher (PID \(launcher.pid))")
        launcher.terminate()
    }

    /// How one check for the display devices went, for logging.
    enum DisplayQueryResult: Equatable {
        case registered
        case notYet(exitCode: Int32)
        case timedOut
        case failedToRun(String)
    }

    /// Whether the desktop process has registered the display devices — the
    /// point after which Direct3D can enumerate adapters — and the reason when
    /// it hasn't.
    ///
    /// `HKLM\HARDWARE\DEVICEMAP\VIDEO` is volatile: wineserver starts with it
    /// empty and the desktop process fills it in while initialising the
    /// display. Each check runs `reg.exe`, about a second, and stopping one
    /// that runs too long mustn't stop the session, whose desktop it is
    /// waiting for.
    static func queryDisplayDevices(_ wine: Wine, timeout: TimeInterval) async -> DisplayQueryResult {
        do {
            let values = try await wine.output(of: .wine(["reg", "query", #"HKLM\HARDWARE\DEVICEMAP\VIDEO"#]),
                                               timeout: timeout, onTimeout: .stopProgram)
            return values.contains(#"\Device\Video"#) ? .registered : .notYet(exitCode: 0)
        } catch WineError.executionFailed(let code) {
            return .notYet(exitCode: code)
        } catch WineError.timedOut {
            return .timedOut
        } catch {
            return .failedToRun("\(error)")
        }
    }
}
