//
//  WineError.swift
//  Shared

import Foundation

public enum WineError: LocalizedError, Equatable {
    case executionFailed(exitCode: Int32)
    case terminatedBySignal(Int32)
    case timedOut(seconds: TimeInterval)
    /// The wrapp has no Wine at all where it should be.
    case notBundled
    case winetricksNotFound
    case winetricksFailed(trick: String)
    /// The program printed Wine's `nodrv_CreateWindow` error: it found no
    /// usable desktop, so it ran without a display.
    case noDisplay
    /// Its `WineWatchdog` said it had stopped getting anywhere, so it was
    /// stopped, `quietFor` after its last sign of progress.
    case stalled(quietFor: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executionFailed(let code):
            return "Wine execution failed with exit code \(code)"
        case .terminatedBySignal(let signal):
            return "Wine was killed by \(SubprocessWatch.signalName(signal))"
        case .timedOut(let seconds):
            return "Wine did not finish within \(SubprocessWatch.duration(seconds)) and was stopped"
        case .notBundled:
            // Seen by the person, so in everyday words; the path is in the log.
            return "Part of what runs the game is missing. Downloading Second Chance again, then making the game's app again, should fix it."
        case .winetricksNotFound:
            return "Winetricks not found in bundle"
        case .winetricksFailed(let trick):
            return "Failed to install winetrick: \(trick)"
        case .noDisplay:
            return "The Windows program found no display to open its windows on (Wine's nodrv_CreateWindow)"
        case .stalled(let quietFor):
            return "Wine showed no sign of progress for \(SubprocessWatch.duration(quietFor)) and was stopped"
        }
    }
}

extension WineError: ProgramExitError {
    public var exitCode: Int32? {
        if case .executionFailed(let code) = self { return code }
        return nil
    }

    public var signal: Int32? {
        if case .terminatedBySignal(let signal) = self { return signal }
        return nil
    }
}
