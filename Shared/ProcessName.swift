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

    /// The executable name of process `pid` as `ps` shows it: from its
    /// argv[0], which Wine 10 rewrites to the Windows path of the program it
    /// runs (every Wine process's actual executable is `bin/wine`). Nil when
    /// the process has gone or isn't readable.
    static func executable(ofPID pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // argc, the exec path, NUL padding, then argv[0].
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        guard index < size, let end = buffer[index..<size].firstIndex(of: 0) else { return nil }
        return executable(fromPSCommand: String(decoding: buffer[index..<end], as: UTF8.self))
    }
}
