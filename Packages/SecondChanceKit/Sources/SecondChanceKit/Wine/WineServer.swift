//
//  WineServer.swift
//  Shared
//
//  A prefix's Wine session, through its `wineserver`: whether it's running,
//  waiting for it to end, and ending it. `wineserver -w` returns once every
//  Wine process in the prefix has exited and the server itself has gone, so
//  that is the signal waited on throughout.
//
//  `wineserver -k9` kills the server alone. A Wine program waiting on it
//  doesn't always notice it has gone, msync or not, and is then left running
//  for good with nothing to end it; so a kill also kills the prefix's
//  programs itself (`programs`), and a launch clears any a kill left behind
//  (`clearLeftovers`).

import Darwin
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

    /// Kill every Wine process in the prefix: the server (`wineserver -k9`),
    /// then the programs it leaves running (`programs`). For a wrapp that has
    /// to exit now, and mustn't leave Wine behind.
    public func kill() async {
        guard hasWine else { return }
        logger.warning("[Wine Cleanup] Killing Wine (wineserver -k9)")
        _ = try? await wine.output(of: .wineserver(["-k9"]))
        let server = self
        await Blocking.run { server.killPrograms("after wineserver -k9") }
    }

    /// The Wine programs running in this prefix, found by the folder each is
    /// working in rather than by asking the server: the prefix, or for Wine's
    /// services the folder the prefix is in. So it finds them too when the
    /// server has gone. Blocks while it lists them.
    public func programs(in processes: ProcessList? = ProcessList.current()) -> [ProcessList.Entry] {
        guard let processes else { return [] }
        let folder = Self.realPath(wine.prefix.deletingLastPathComponent())
        return processes.wine.filter { entry in
            guard let cwd = ProcessList.workingDirectory(of: entry.pid) else { return false }
            return cwd == folder || cwd.hasPrefix(folder + "/")
        }
    }

    /// Whether `pid` is known to be working in another folder than this
    /// prefix's: a Wine program of some other session. False when it can't
    /// be told.
    public func isElsewhere(_ pid: pid_t) -> Bool {
        guard let cwd = ProcessList.workingDirectory(of: pid) else { return false }
        let folder = Self.realPath(wine.prefix.deletingLastPathComponent())
        return cwd != folder && !cwd.hasPrefix(folder + "/")
    }

    /// Kill the programs left running in the prefix by a session whose server
    /// has gone — a `wineserver -k9`, or a server that crashed. They never
    /// finish, nothing waits for them (`isRunning` asks the server), and a
    /// launch would take the game among them for its own and wait for ever
    /// for its window. Nothing while the session is running. How many.
    @discardableResult
    public func clearLeftovers() async -> Int {
        guard hasWine, await !isRunning else { return 0 }
        let server = self
        return await Blocking.run { server.killPrograms("with no wineserver, left from a session that was killed") }
    }

    /// SIGKILL the prefix's programs (`programs`); `why` says when, for the log.
    @discardableResult
    func killPrograms(_ why: String) -> Int {
        let left = programs()
        guard !left.isEmpty else { return 0 }
        let names = left.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
        logger.warning("[Wine Cleanup] \(left.count) Wine programs still running \(why): killing them: \(names)")
        for entry in left { Darwin.kill(entry.pid, SIGKILL) }
        return left.count
    }

    /// `url`'s path with every symlink resolved, as the kernel reports a
    /// working directory: /private/var, not /var.
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
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

    /// How firmly `shutDown` is ending the session.
    public enum ShutdownStep: Sendable, Equatable {
        /// Waiting for Wine to finish by itself.
        case waiting
        /// Asking Wine's programs to stop (`wineserver -k`).
        case stopping
        /// Killing them (`wineserver -k9`).
        case killing
    }

    /// Wait for the session to end, with escalating force.
    ///
    /// Wine gets `gracePeriod` to finish by itself: a game that quit leaves
    /// explorer and Wine's services to wind down, which takes a few seconds,
    /// while someone quitting the wrapp wants it gone sooner. Once its
    /// programs have all ended, though, only the server and Wine's services
    /// are left, which linger 3 s after the last program before ending:
    /// they are stopped then rather than waited out (`waitUntilProgramsEnd`). Then `stop()`
    /// and, if that isn't enough, `kill()`, each followed by a wait of
    /// `stopPeriod`, so
    /// this returns only once Wine has gone, or a kill has had its chance and
    /// been logged as failing. Whether Wine is known to have ended.
    ///
    /// `onStep` hears each step as it starts, for someone waiting to be told
    /// (the wrapp's closing window); not called without a bundled Wine.
    @discardableResult
    public func shutDown(gracePeriod: TimeInterval = 5, stopPeriod: TimeInterval = 5,
                         onStep: @Sendable (ShutdownStep) -> Void = { _ in }) async -> Bool {
        guard hasWine else { return true }
        let started = Date()
        // However it ended: a server that has gone can leave programs behind
        // (`kill`), even after `wineserver -k` on a heavily loaded Mac.
        let server = self
        defer { server.killPrograms("after Wine ended") }
        logger.notice("[Wine Cleanup] Waiting for Wine to finish (wineserver -w)...")
        onStep(.waiting)
        switch await waitUntilStoppedOrIdle(timeout: gracePeriod) {
        case .stopped:
            logger.notice("[Wine Cleanup] Wine finished by itself after \(SubprocessWatch.duration(Date().timeIntervalSince(started)))")
            return true
        case .idle:
            // Routine, so not a step for the closing window to tell.
            logger.notice("[Wine Cleanup] Wine's programs all ended after \(SubprocessWatch.duration(Date().timeIntervalSince(started))): stopping its server and services rather than waiting for them to linger (wineserver -k)")
        case .timedOut:
            logger.warning("[Wine Cleanup] Wine was still running after \(Int(gracePeriod)) s: stopping it (wineserver -k)")
            onStep(.stopping)
        }
        await stop()
        if await waitUntilStopped(timeout: stopPeriod) {
            logger.notice("[Wine Cleanup] Wine stopped")
            return true
        }

        logger.error("[Wine Cleanup] Wine ignored SIGTERM: killing it (wineserver -k9)")
        onStep(.killing)
        await kill()
        if await waitUntilStopped(timeout: stopPeriod) {
            logger.notice("[Wine Cleanup] Wine killed")
            return true
        }
        logger.error("[Wine Cleanup] Wine was still running \(SubprocessWatch.duration(stopPeriod)) after SIGKILL")
        return false
    }

    /// How the grace period of `shutDown` ended.
    enum GraceOutcome: Sendable {
        /// The session ended.
        case stopped
        /// Its programs ended, leaving the server.
        case idle
        case timedOut
    }

    /// Wait for the session to end or its programs to, whichever is first,
    /// for at most `timeout`.
    func waitUntilStoppedOrIdle(timeout: TimeInterval) async -> GraceOutcome {
        await withTaskGroup(of: GraceOutcome.self) { group in
            group.addTask { await waitUntilStopped(timeout: timeout) ? .stopped : .timedOut }
            group.addTask { await waitUntilProgramsEnd(timeout: timeout) ? .idle : .timedOut }
            // A wait that gave up early (no process list) leaves it to the other.
            var outcome = GraceOutcome.timedOut
            for await result in group where result != .timedOut {
                outcome = result
                break
            }
            group.cancelAll()
            return outcome
        }
    }

    /// Wine's system programs: its services and the desktop. They wait for
    /// the server to end, so they keep running through its linger, and end
    /// with it. Stopping them with `wineserver -k` rather than letting the
    /// server signal them loses nothing: the registry is the server's, and
    /// it saves it as it exits either way; they keep nothing else.
    static let systemPrograms: Set<String> = [
        "wineserver", "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "explorer.exe",
    ]

    /// Wait until no program is running in the prefix but the server and
    /// Wine's system programs (`systemPrograms`), for at most `timeout`.
    /// Whether that came; false too when what is running can't be listed,
    /// or the task is cancelled. Each program's exit is waited on, then the
    /// list taken again, as one may have started another.
    func waitUntilProgramsEnd(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let server = self
        while !Task.isCancelled {
            let left = await Blocking.run { () -> [pid_t]? in
                guard let processes = ProcessList.current() else { return nil }
                return server.programs(in: processes)
                    .filter { !Self.systemPrograms.contains($0.name.lowercased()) }
                    .map(\.pid)
            }
            guard let left else { return false }
            if left.isEmpty { return true }
            guard await Self.waitForAnyExit(of: left, until: deadline) else { return false }
        }
        return false
    }

    /// Wait until one of `pids` exits (or has), or `deadline`, or the task is
    /// cancelled. Whether one did, or the task was cancelled.
    private static func waitForAnyExit(of pids: [pid_t], until deadline: Date) async -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        let exited = DispatchSemaphore(value: 0)
        return await withTaskCancellationHandler {
            await Blocking.run {
                let sources = pids.map { pid in
                    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
                    source.setEventHandler { exited.signal() }
                    source.resume()
                    return source
                }
                defer { sources.forEach { $0.cancel() } }
                // Gone before its source was watching: that one would never fire.
                if pids.contains(where: { Darwin.kill($0, 0) != 0 && errno == ESRCH }) { return true }
                return exited.wait(timeout: .now() + remaining) == .success
            }
        } onCancel: {
            exited.signal()
        }
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
            let stopping = try wine.start(.wineserver(["-k"]), output: .discard)
            if !stopping.waitUntilExit(within: 10) {
                logger.warning("wineserver -k was still running after 10 s")
            }
        } catch {
            logger.warning("Couldn't stop Wine (wineserver -k): \(error.localizedDescription)")
        }
    }
}
