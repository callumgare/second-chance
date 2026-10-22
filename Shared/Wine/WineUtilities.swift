//
//  WineUtilities.swift
//  Shared Wine utilities
//
//  Minimal Wine utilities that can be used by both WrappTemplate and SecondChance
//  without requiring SecondChance-specific dependencies

import Foundation
import Logging

private nonisolated let wineUtilitiesLogger = Logger(label: "au.gare.callum.second-chance.Shared.WineUtilities")

/// Utility functions for Wine operations that don't require progress reporting
class WineUtilities {

    /// Wait for the Wine session to end, with escalating force: `wineserver
    /// -w` returns once every Wine process in the prefix has exited and the
    /// server itself has gone, so that is the signal waited on at each step.
    ///
    /// - `gracefulTimeout`: how long Wine gets to finish by itself. A game
    ///   that quit leaves explorer and Wine's services to wind down, which
    ///   takes a few seconds; someone quitting the wrapp wants it gone sooner.
    ///
    /// Then `wineserver -k` (SIGTERM) and, if that isn't enough, `-k9`
    /// (SIGKILL), each followed by another wait, so this returns only once
    /// Wine has gone or a kill has had its chance and been logged as failing.
    /// Returns whether Wine is known to have ended.
    @discardableResult
    static func waitTillWineserverStopped(at wrappPath: URL, customPrefixDir: URL? = nil,
                                          gracefulTimeout: TimeInterval = 5) -> Bool {
        let wine = WineEnvironment(appPath: wrappPath, customPrefixDir: customPrefixDir)
        let wineserver = wine.wineBinDir.appendingPathComponent("wineserver")
        // A ScummVM wrapp has no Wine at all.
        guard FileManager.default.fileExists(atPath: wineserver.path) else { return true }

        func run(_ arguments: [String]) -> Process? {
            let process = Process()
            process.executableURL = wineserver
            process.arguments = arguments
            process.environment = wine.environmentVariables()
            do {
                try process.run()
                return process
            } catch {
                wineUtilitiesLogger.error("[Wine Cleanup] Couldn't run wineserver \(arguments.joined(separator: " ")): \(error.localizedDescription)")
                return nil
            }
        }

        /// Whether Wine ended within `timeout`, by `wineserver -w` returning.
        func waitForSessionEnd(_ timeout: TimeInterval) -> Bool {
            guard let waiter = run(["-w"]) else { return false }
            let ended = DispatchSemaphore(value: 0)
            waiter.terminationHandler = { _ in ended.signal() }
            if ended.wait(timeout: .now() + timeout) == .success { return true }
            waiter.terminate()
            return false
        }

        let started = Date()
        wineUtilitiesLogger.notice("[Wine Cleanup] Waiting for Wine to finish (wineserver -w)...")
        if waitForSessionEnd(gracefulTimeout) {
            wineUtilitiesLogger.notice("[Wine Cleanup] Wine finished by itself after \(SubprocessWatch.duration(Date().timeIntervalSince(started)))")
            return true
        }

        wineUtilitiesLogger.warning("[Wine Cleanup] Wine was still running after \(Int(gracefulTimeout)) s: stopping it (wineserver -k)")
        run(["-k"])?.waitUntilExit()
        if waitForSessionEnd(5) {
            wineUtilitiesLogger.notice("[Wine Cleanup] Wine stopped")
            return true
        }

        wineUtilitiesLogger.error("[Wine Cleanup] Wine ignored SIGTERM: killing it (wineserver -k9)")
        run(["-k9"])?.waitUntilExit()
        if waitForSessionEnd(5) {
            wineUtilitiesLogger.notice("[Wine Cleanup] Wine killed")
            return true
        }
        wineUtilitiesLogger.error("[Wine Cleanup] Wine was still running 5 s after SIGKILL")
        return false
    }
}
