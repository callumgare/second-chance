//
//  ProcessName.swift
//  Shared
//
//  The executable name in a `ps` listing's command column.

import Foundation

nonisolated enum ProcessName {
    /// The executable's file name from a `ps` `comm`/`command` value.
    ///
    /// Wine 9 reported a game as `Alibi.exe`, but Wine 10 reports its whole
    /// Windows path, backslashes and all, with a trailing space:
    /// `C:\Program Files (x86)\…\Alibi.exe `. `lastPathComponent` only splits
    /// on `/`, so on its own it hands back that entire path and nothing
    /// matching the exe by name ever finds the game.
    static func executable(fromPSCommand command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let name = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? trimmed
        return name.trimmingCharacters(in: .whitespaces)
    }
}
