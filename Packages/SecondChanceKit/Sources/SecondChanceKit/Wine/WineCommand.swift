//
//  WineCommand.swift
//  Shared
//
//  What to run with Wine, apart from how: `Wine.run`, `output(of:)` and
//  `start` take one of these.

import Foundation

nonisolated public struct WineCommand: Sendable, Equatable {
    enum Tool: Sendable, Equatable {
        case wine
        case wineserver
        /// A shell script run by bash in Wine's environment: winetricks.
        case script(URL)
    }

    let tool: Tool
    /// What follows the tool on its command line.
    let arguments: [String]
    /// Where it runs from; the parent's working directory when nil.
    let directory: URL?

    /// `wine <arguments>`: a builtin such as `reg` or `explorer.exe`, or a program.
    public static func wine(_ arguments: [String], in directory: URL? = nil) -> Self {
        Self(tool: .wine, arguments: arguments, directory: directory)
    }

    /// `wine <exe> <arguments>`.
    public static func program(_ exe: String, _ arguments: [String] = []) -> Self {
        .wine([exe] + arguments)
    }

    /// `wine start /wait [/unix] <exe> <arguments>`: what an installer needs to
    /// find its own folder. `unixPath` says `exe` is a Mac path; without it,
    /// `exe` is found in `directory`.
    public static func start(_ exe: String, _ arguments: [String] = [], unixPath: Bool = true,
                             in directory: URL? = nil) -> Self {
        .wine(["start", "/wait"] + (unixPath ? ["/unix"] : []) + [exe] + arguments, in: directory)
    }

    public static func wineserver(_ arguments: [String]) -> Self {
        Self(tool: .wineserver, arguments: arguments, directory: nil)
    }

    public static func script(_ script: URL, _ arguments: [String]) -> Self {
        Self(tool: .script(script), arguments: arguments, directory: nil)
    }

    /// Whether it's one of the wrapp's own Wine programs, rather than a script
    /// run by the system's bash.
    var isBundled: Bool {
        if case .script = tool { return false }
        return true
    }

    /// The program the process runs.
    public func executable(in wine: Wine) -> URL {
        switch tool {
        case .wine: wine.binDir.appendingPathComponent("wine")
        case .wineserver: wine.binDir.appendingPathComponent("wineserver")
        case .script: URL(fileURLWithPath: "/bin/bash")
        }
    }

    /// The process's arguments.
    public var processArguments: [String] {
        if case .script(let script) = tool { return [script.path] + arguments }
        return arguments
    }

    /// `wine setup.exe`, `wine reg`, `wineserver`, `winetricks`: what to call
    /// it in the log. For `start`, the program it starts.
    public var displayName: String {
        switch tool {
        case .wineserver: return "wineserver"
        case .script(let script): return script.lastPathComponent
        case .wine: break
        }
        var rest = arguments[...]
        if rest.first?.lowercased() == "start" {
            rest = rest.dropFirst()
            while let flag = rest.first, ["/wait", "/unix", "/min", "/max", "/b"].contains(flag.lowercased()) {
                rest = rest.dropFirst()
            }
        }
        guard let program = rest.first else { return "wine" }
        let name = program.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? program
        return "wine \(name)"
    }

    /// A shell command that runs it with the variables Second Chance sets,
    /// one per line: what someone would paste into a terminal to run it again.
    public func commandLine(in wine: Wine) -> String {
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let variables = wine.variables
            .sorted { $0.key < $1.key }
            .map { "  \($0.key)=\(quote($0.value)) \\" }
        let command = ([executable(in: wine).path] + processArguments).map(quote).joined(separator: " ")
        let directory = directory.map { "cd \(quote($0.path)) && " } ?? ""
        return (["\(directory)env \\"] + variables + ["  " + command]).joined(separator: "\n")
    }
}
