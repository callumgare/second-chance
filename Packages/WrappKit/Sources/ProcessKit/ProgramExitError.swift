//
//  ProgramExitError.swift
//  ProcessKit
//

/// An error saying how a program ended. Its exit code or signal goes in a
/// failure report's `exit_code` or `signal` tag, as a game run's does: a
/// number, which holds no path, and often the whole story (126: it couldn't
/// be run at all).
nonisolated public protocol ProgramExitError: Error {
    var exitCode: Int32? { get }
    var signal: Int32? { get }
}
