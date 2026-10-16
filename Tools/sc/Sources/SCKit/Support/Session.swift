import ArgumentParser
import Foundation

/// Options every command takes.
struct GlobalOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "How streamed tool output is shown: collapsed, full or raw.",
        discussion: "Default: collapsed in an interactive terminal, raw when output is piped or redirected."
    ))
    var logs: LogMode?

    // `--on` is taken out of the arguments before parsing (see Entry), so the
    // rest of the command line can be forwarded to the remote Mac untouched.
    // It is declared here only so it appears in --help and parses if passed
    // after `--` handling has already removed it.
    @Option(name: .customLong("on"), help: ArgumentHelp(
        "Run this command on a remote Mac: <host>[:<path>].",
        discussion: "Syncs the repo there first. <path> defaults to this repo's path relative to your home directory.",
        valueName: "host[:path]"
    ))
    var remote: String?
}

/// `--skip-app-build`, on every command that would otherwise build the app first.
struct AppBuildOptions: ParsableArguments {
    @Flag(help: "Use the app build already in DerivedData instead of building it first.")
    var skipAppBuild = false
}

/// `--wrapps-dir`, on every command that reads or writes wrapps.
struct WrappsDirOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Where wrapps are kept. Default: built-apps/ in the repo.", valueName: "dir"))
    var wrappsDir: String?

    func resolve(_ repo: Repo) -> URL {
        guard let wrappsDir else { return repo.defaultWrappsDir }
        return URL(fileURLWithPath: (wrappsDir as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

/// What one run of sc is working with.
struct Session: Sendable {
    let repo: Repo
    let ui: UI
    let terminal: TerminalEnvironment
    let mode: LogMode

    /// The session the running command started, for the entry point's error reporting.
    nonisolated(unsafe) static var active: Session?

    static func start(_ global: GlobalOptions) throws -> Session {
        let terminal = TerminalEnvironment.detect()
        let mode = global.logs ?? terminal.defaultLogMode
        let repo = try Repo.locate()
        let session = Session(
            repo: repo,
            ui: UI(environment: terminal, mode: mode, logsDir: repo.scLogs),
            terminal: terminal,
            mode: mode
        )
        active = session
        return session
    }
}

/// The command line as the user gave it (minus the program name and any
/// `--on`), so it can be re-run elsewhere: in the GUI session, or remotely.
enum Invocation {
    nonisolated(unsafe) static var arguments: [String] = []

    /// The arguments with `--logs <mode>` made explicit, so a re-run under a
    /// pty shows output the way the original terminal would have.
    static func forwarding(logs mode: LogMode, _ args: [String] = arguments) -> [String] {
        let end = args.firstIndex(of: "--") ?? args.endIndex
        let head = args[..<end]
        if head.contains("--logs") || head.contains(where: { $0.hasPrefix("--logs=") }) { return args }
        var out = Array(head)
        out += ["--logs", mode.rawValue]
        out += args[end...]
        return out
    }
}
