//
//  Subcommands.swift
//  WrappTemplate
//
//  Parsing helpers for CLI subcommands invoked via direct binary invocation
//  (e.g. `/path/Game.app/Contents/MacOS/WrappTemplate wine --version`).
//
//  These helpers are pure (no I/O, no side effects) so they can be exercised
//  directly by unit tests if added to the test target.

import Foundation

// MARK: - Subcommand parsing

/// Extract the arguments for the `wine` subcommand from the raw argv array.
///
/// When the wrapper binary is invoked directly from a terminal, it can act as a
/// thin pass-through to the bundled Wine binary for this game's prefix:
///
///     /path/Game.app/Contents/MacOS/WrappTemplate wine --version
///     /path/Game.app/Contents/MacOS/WrappTemplate wine '\start' explorer.exe
///     /path/Game.app/Contents/MacOS/WrappTemplate wine C:\windows\regedit.exe
///
/// This helper drops `argv[0]` and, if the first remaining token is `"wine"`,
/// returns all subsequent tokens to forward to the Wine binary verbatim.
///
/// Returns `nil` for any other invocation — a normal game launch (double-click,
/// `open`), the existing `--debug` / `--debug-options` flags, or no arguments at
/// all — so the caller falls through to the regular game-launch flow unchanged.
///
/// - Parameter arguments: The raw command-line arguments (typically
///   `CommandLine.arguments` or `ProcessInfo.processInfo.arguments`).
/// - Returns: The arguments to forward to Wine (possibly empty if `wine` was
///   given with no further args), or `nil` if the `wine` subcommand was not
///   requested.
func extractWineSubcommand(from arguments: [String]) -> [String]? {
    // arguments[0] is the executable path; the subcommand, if any, is at index 1.
    guard arguments.count >= 2 else {
        return nil
    }
    guard arguments[1] == "wine" else {
        return nil
    }
    // Everything after the `wine` token is forwarded verbatim to the Wine binary.
    return Array(arguments.dropFirst(2))
}
