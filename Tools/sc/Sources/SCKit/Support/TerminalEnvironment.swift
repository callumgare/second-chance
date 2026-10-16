import ArgumentParser
import Foundation

/// How streamed tool output (xcodebuild, tests, the headless app, rsync) is shown.
enum LogMode: String, CaseIterable, ExpressibleByArgument, Sendable {
    /// Each step shows its last few lines while it runs, then collapses to one line.
    case collapsed
    /// Every formatted (xcbeautify) line.
    case full
    /// The tools' own output, unaltered.
    case raw
}

/// What the terminal sc is attached to can do. Decided once, by the process
/// the user invoked, and forwarded to re-runs (GUI session, `--on`) as an
/// explicit `--logs` — both of those run under a pty and would otherwise look
/// interactive even when the original caller was piping.
struct TerminalEnvironment: Sendable {
    /// Live, redrawing output is allowed: stdout *and* stderr are terminals and
    /// `TERM` isn't `dumb`. stdout counts because results go there — capturing
    /// it (`open "$(sc wrapp build x)"`) means a script is driving.
    let isInteractive: Bool
    let isColored: Bool
    /// Keystrokes can be read (stdin is a terminal).
    let canReadKeys: Bool

    static func detect() -> TerminalEnvironment {
        let env = ProcessInfo.processInfo.environment
        let dumb = env["TERM"] == "dumb"
        let interactive = isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0 && !dumb
        let colored: Bool
        if env["NO_COLOR"] != nil || dumb {
            colored = false
        } else if env["CLICOLOR_FORCE"] != nil {
            colored = true
        } else {
            colored = isatty(STDERR_FILENO) != 0
        }
        return TerminalEnvironment(
            isInteractive: interactive,
            isColored: colored,
            canReadKeys: interactive && isatty(STDIN_FILENO) != 0
        )
    }

    var defaultLogMode: LogMode { isInteractive ? .collapsed : .raw }

    /// Terminal width and height, read fresh (so a resize is picked up).
    static func size() -> (columns: Int, rows: Int)? {
        var w = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 else { return nil }
        return (Int(w.ws_col), Int(w.ws_row))
    }
}
