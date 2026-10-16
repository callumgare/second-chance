import Foundation

/// `--on <host>[:<path>]`: run the same command on another Mac.
///
/// 1. rsync this repo there (everything but per-machine output: `.git`,
///    `built-apps`, `test-results`, `tmp`, sc's own `.build` and logs);
/// 2. `ssh` in and run `./sc` with the same arguments, minus `--on`, plus an
///    explicit `--logs` so the output looks the way it would have here.
///
/// Output stays on the remote Mac: test results and reports are written to
/// its `test-results/`, not copied back.
///
/// On the remote Mac, commands that open windows re-run themselves in its GUI
/// session as usual — someone must be logged in at its console.
enum Remote {
    struct Target: Equatable {
        let host: String
        /// The repo's path there; `~/` paths are relative to the remote home.
        let path: String
    }

    /// Take `--on` out of the arguments (only before a `--` terminator).
    static func extractTarget(from arguments: [String]) -> (target: String?, rest: [String]) {
        var rest: [String] = []
        var target: String?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" {
                rest += arguments[index...]
                break
            }
            if arg == "--on", index + 1 < arguments.count {
                target = arguments[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("--on=") {
                target = String(arg.dropFirst("--on=".count))
                index += 1
                continue
            }
            rest.append(arg)
            index += 1
        }
        return (target, rest)
    }

    /// Split `host[:path]`, defaulting the path to this repo's path relative
    /// to the home directory (or the same absolute path when it isn't under it).
    static func parse(_ target: String, localRoot: URL, home: String = NSHomeDirectory()) -> Target {
        if let colon = target.firstIndex(of: ":") {
            return Target(host: String(target[..<colon]), path: String(target[target.index(after: colon)...]))
        }
        let root = localRoot.standardizedFileURL.path
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        let path = root.hasPrefix(homePrefix) ? "~/" + root.dropFirst(homePrefix.count) : root
        return Target(host: target, path: path)
    }

    /// The remote command line, written to read the same in bash, zsh and
    /// fish (whichever is the remote login shell): single-quoted words, `~/`
    /// left unquoted so it expands.
    static func remoteCommand(path: String, arguments: [String]) -> String {
        let dir = path.hasPrefix("~/") ? "~/" + quote(String(path.dropFirst(2))) : quote(path)
        return "cd \(dir) && ./sc " + arguments.map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let excludes = [".git", "built-apps", "test-results", "tmp", "Tools/sc/.build", "DerivedData/sc-logs"]

    static func run(on rawTarget: String, arguments: [String]) async throws -> Int32 {
        let terminal = TerminalEnvironment.detect()
        let explicitMode = arguments.firstIndex(of: "--logs").flatMap { arguments.indices.contains($0 + 1) ? LogMode(rawValue: arguments[$0 + 1]) : nil }
        let mode = explicitMode ?? terminal.defaultLogMode
        let repo = try Repo.locate()
        let ui = UI(environment: terminal, mode: mode, logsDir: repo.scLogs)
        Session.active = Session(repo: repo, ui: ui, terminal: terminal, mode: mode)
        let target = parse(rawTarget, localRoot: repo.root)

        let forwarded = Invocation.forwarding(logs: mode, arguments)

        let rsyncArgs = ["-aX", "--delete"] + excludes.flatMap { ["--exclude", $0] }
            + ["./", "\(target.host):\(target.path)/"]
        try await ui.logStep("Sync to \(target.host)", log: "sync", success: "Synced to \(target.host):\(target.path)") { sink in
            try await Proc.stream("rsync", rsyncArgs, cwd: repo.root) { await sink.line($0) }
        }

        ui.line(ui.format("\(.primary("▸ On \(target.host): sc \(arguments.joined(separator: " "))"))"))
        let sshArgs = (terminal.isInteractive ? ["-t"] : ["-T"]) + [target.host, remoteCommand(path: target.path, arguments: forwarded)]
        return try await Proc.inheritingTerminal("ssh", sshArgs)
    }
}
