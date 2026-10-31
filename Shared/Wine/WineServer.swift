//
//  WineServer.swift
//  Shared
//
//  A prefix's Wine session, through its `wineserver`: whether it's running,
//  waiting for it to end, and ending it. `wineserver -w` returns once every
//  Wine process in the prefix has exited and the server itself has gone, so
//  that is the signal waited on throughout.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.WineServer")

nonisolated extension Wine {
    public var server: WineServer { WineServer(wine: self) }
}

/// Without a bundled Wine — a ScummVM wrapp — there's no session: it isn't
/// running, the waits return at once, and stopping it does nothing.
nonisolated public struct WineServer: Sendable {
    let wine: Wine

    private var hasWine: Bool {
        FileManager.default.fileExists(atPath: WineCommand.wineserver([]).executable(in: wine).path)
    }

    /// Whether the session is running (`wineserver -k0`).
    public var isRunning: Bool {
        get async {
            guard hasWine else { return false }
            do {
                _ = try await wine.output(of: .wineserver(["-k0"]))
                return true
            } catch WineError.executionFailed {
                return false
            } catch {
                logger.error("Couldn't check whether Wine is running: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Ask every Wine process in the prefix to end (`wineserver -k`, SIGTERM),
    /// and wait for the request, not for them. Whether it was made.
    @discardableResult
    public func stop() async -> Bool {
        guard hasWine else { return true }
        do {
            _ = try await wine.output(of: .wineserver(["-k"]))
            return true
        } catch WineError.executionFailed(let code) {
            // As when no session is running.
            logger.notice("wineserver -k exited \(code)")
            return false
        } catch {
            logger.warning("Couldn't stop Wine (wineserver -k): \(error.localizedDescription)")
            return false
        }
    }

    /// Kill every Wine process in the prefix (`wineserver -k9`, SIGKILL): for a
    /// wrapp that has to exit now, and mustn't leave Wine behind.
    public func kill() async {
        guard hasWine else { return }
        logger.warning("[Wine Cleanup] Killing Wine (wineserver -k9)")
        _ = try? await wine.output(of: .wineserver(["-k9"]))
    }

    /// Wait for the session to end, for at most `timeout`. Whether it did: at
    /// once when none is running. Cancelling the task stops the wait, not Wine.
    public func waitUntilStopped(timeout: TimeInterval) async -> Bool {
        guard hasWine else { return true }
        do {
            _ = try await wine.output(of: .wineserver(["-w"]), timeout: timeout, onTimeout: .stopProgram)
            return true
        } catch {
            return false
        }
    }

    /// Call `handler` once the session has ended. Returns the waiter, to
    /// `terminate()` when the wait is no longer wanted — then `handler`
    /// isn't called — or nil when there's no Wine, or it couldn't be started.
    public func onStop(_ handler: @escaping @Sendable () -> Void) -> WineProcess? {
        guard hasWine else { return nil }
        let waiter: WineProcess
        do {
            waiter = try wine.start(.wineserver(["-w"]), output: .discard)
        } catch {
            logger.error("[Wine Cleanup] Couldn't wait for Wine to finish (wineserver -w): \(error.localizedDescription)")
            return nil
        }
        Task.detached {
            // Killed by a signal: terminated, so no longer wanted.
            if case .exited = await waiter.waitUntilExit(timeout: nil) { handler() }
        }
        return waiter
    }

    /// Wait for the session to end, with escalating force.
    ///
    /// Wine gets `gracePeriod` to finish by itself: a game that quit leaves
    /// explorer and Wine's services to wind down, which takes a few seconds,
    /// while someone quitting the wrapp wants it gone sooner. Then `stop()`
    /// and, if that isn't enough, `kill()`, each followed by a wait of
    /// `stopPeriod`, so
    /// this returns only once Wine has gone, or a kill has had its chance and
    /// been logged as failing. Whether Wine is known to have ended.
    @discardableResult
    public func shutDown(gracePeriod: TimeInterval = 5, stopPeriod: TimeInterval = 5) async -> Bool {
        guard hasWine else { return true }
        let started = Date()
        logger.notice("[Wine Cleanup] Waiting for Wine to finish (wineserver -w)...")
        if await waitUntilStopped(timeout: gracePeriod) {
            logger.notice("[Wine Cleanup] Wine finished by itself after \(SubprocessWatch.duration(Date().timeIntervalSince(started)))")
            return true
        }

        logger.warning("[Wine Cleanup] Wine was still running after \(Int(gracePeriod)) s: stopping it (wineserver -k)")
        await stop()
        if await waitUntilStopped(timeout: stopPeriod) {
            logger.notice("[Wine Cleanup] Wine stopped")
            return true
        }

        logger.error("[Wine Cleanup] Wine ignored SIGTERM: killing it (wineserver -k9)")
        await kill()
        if await waitUntilStopped(timeout: stopPeriod) {
            logger.notice("[Wine Cleanup] Wine killed")
            return true
        }
        logger.error("[Wine Cleanup] Wine was still running \(SubprocessWatch.duration(stopPeriod)) after SIGKILL")
        return false
    }

    /// Wait for the programs an installer left running to finish, as a run
    /// of its own: logged, timed and stall-watched like any other
    /// (`Wine.run`), and stopping the session if it times out or stalls.
    public func waitUntilProgramsExit(timeout: TimeInterval?, watchdog: WineWatchdog? = nil) async throws {
        try await wine.run(.wineserver(["-w"]), timeout: timeout, watchdog: watchdog)
    }

    /// `stop()`, for code that can't wait asynchronously: the launcher's
    /// cancellation handler. Blocks until the request has been made.
    func stopNow() {
        guard hasWine else { return }
        do {
            try wine.start(.wineserver(["-k"]), output: .discard).process.waitUntilExit()
        } catch {
            logger.warning("Couldn't stop Wine (wineserver -k): \(error.localizedDescription)")
        }
    }
}
