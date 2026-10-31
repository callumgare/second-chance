//
//  WineWatchdog.swift
//  Shared

import Foundation

/// Watches a Wine program `runWine` is waiting for, and says whether it is
/// still getting somewhere (`GameInstallerRunner`'s `InstallStallWatch`).
public protocol WineWatchdog: AnyObject, Sendable {
    /// The program printed a line.
    func sawOutput()
    /// Asked every few seconds while the program runs.
    func check() -> WineWatchdogVerdict
}

public enum WineWatchdogVerdict: Sendable, Equatable {
    case carryOn
    /// Carry on, and don't count this time towards the timeout: the program
    /// is waiting on the person, who may take as long as they like.
    case waitingOnPerson
    /// Stop it: no sign of progress for this long.
    case stalled(quietFor: TimeInterval)
}
