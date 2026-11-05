import Foundation

/// Where sc finds the tools it runs by name (xcbeautify, xchtmlreport, …).
enum ToolPath {
    /// Homebrew's folders, Apple silicon's then Intel's.
    static let homebrew = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// `path` with Homebrew's folders added at the end when they're missing.
    /// A command run over SSH gets only the login shell's bare PATH, without
    /// what a profile adds, and a test user ([test sessions](docs/dev-cli.md#test-sessions))
    /// has no profile that adds Homebrew, so its runs stopped at
    /// "'xcbeautify' isn't installed".
    static func withHomebrew(_ path: String?) -> String {
        var parts = (path ?? "").split(separator: ":").map(String.init)
        for dir in homebrew where !parts.contains(dir) { parts.append(dir) }
        return parts.joined(separator: ":")
    }

    /// Put Homebrew on this process's PATH, for it and everything it starts.
    static func addHomebrew() {
        setenv("PATH", withHomebrew(ProcessInfo.processInfo.environment["PATH"]), 1)
    }
}
