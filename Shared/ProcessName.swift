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

    /// Whether a process named `name` (compared without case: "steam.exe")
    /// is running, as `ps` lists it. True when `ps` can't be run, so a caller
    /// waiting for one to go doesn't give up on a failed check.
    static func isRunning(_ name: String) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return true
        }
        // Read before waiting: the list can be bigger than the pipe's buffer.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let wanted = name.lowercased()
        return output.split(separator: "\n").contains { executable(fromPSCommand: String($0)).lowercased() == wanted }
    }
}
