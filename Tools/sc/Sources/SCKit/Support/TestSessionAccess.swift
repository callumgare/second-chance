import Foundation

/// How sc reaches a test session (docs/dev-cli.md#test-sessions) from the Mac
/// it's run on: commands over SSH as the Mac's own user or a test user (or,
/// for this Mac, here), a program run once in a user's GUI session, and a
/// Screen Sharing window into a session. `session setup` and
/// `session view` use it.
enum TestSessionAccess {
    /// A command as the user sc runs as: here, or over SSH on `mac`. It's
    /// bash there too, whatever that user's login shell: fish can't read an
    /// `if … fi` or a `for` loop.
    static func asConsoleUser(_ mac: String?, _ command: String, input: String? = nil) async throws -> Proc.Collected {
        if let mac { return try await ssh(mac, "/bin/bash -c \(Remote.quote(command))", input: input) }
        return try await Proc.collect("/bin/bash", ["-c", command], input: input)
    }

    static func ssh(_ destination: String, _ command: String, input: String? = nil) async throws -> Proc.Collected {
        try await Proc.collect("/usr/bin/ssh", ["-o", "BatchMode=yes", destination, command], input: input)
    }

    /// A script that runs `arguments` once in the SSH user's GUI session, as
    /// a LaunchAgent (`open` or the keychain from SSH reach no GUI session),
    /// and streams its output back through a named pipe, so nothing it prints
    /// is written to disk.
    /// `timeout`: how long to wait for its output, longer for one that waits
    /// on the person (a prompt on the Mac's screen). `withErrors`: its
    /// stderr comes back too, merged with its stdout.
    static func inGUISession(_ arguments: [String], timeout: Int = 30, withErrors: Bool = false) -> String {
        let program = arguments.map { "<string>\($0.replacingOccurrences(of: "&", with: "&amp;"))</string>" }.joined()
        let errors = withErrors ? "<key>StandardErrorPath</key><string>$dir/out</string>" : ""
        return """
        set -eu
        label=au.gare.callum.second-chance.once-$$
        dir=$(mktemp -d); chmod 700 "$dir"; trap 'launchctl bootout gui/$(id -u)/$label 2>/dev/null; rm -rf "$dir"' EXIT
        mkfifo -m 600 "$dir/out"
        cat > "$dir/job.plist" <<P
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>$label</string>
        <key>ProgramArguments</key><array>\(program)</array>
        <key>StandardOutPath</key><string>$dir/out</string>\(errors)<key>RunAtLoad</key><true/></dict></plist>
        P
        launchctl bootstrap gui/$(id -u) "$dir/job.plist"
        perl -e 'alarm \(timeout); exec "cat", @ARGV' "$dir/out"
        """
    }

    /// A Screen Sharing window here into the user's session, logged in with
    /// the password from the test Mac's keychain. That keychain is locked
    /// over SSH, so it's read in the GUI session, comes back through a pipe,
    /// and goes to Screen Sharing by AppleScript, not a command line any
    /// process here could read. It's never written anywhere. Screen Sharing
    /// won't connect a Mac to itself, so this Mac's sessions are reached
    /// through an SSH tunnel to its own Screen Sharing. With
    /// `tunnelEndsWithWindow`, that tunnel ends once the window it carries
    /// closes: ssh runs a command that outlasts Screen Sharing connecting,
    /// then waits only for the connections still forwarded.
    static func openScreenSharing(_ user: String, on mac: String?, tunnelEndsWithWindow: Bool = false) async throws {
        let script = inGUISession(["/usr/bin/security", "find-generic-password", "-s", SessionPool.keychainService, "-a", user, "-w"])
        let result = try await asConsoleUser(mac, "bash -s", input: script)
        let password = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !password.isEmpty, !password.contains("\n") else {
            throw SCError("Couldn't read \(user)'s password from \(mac ?? "this Mac")'s keychain.",
                          hints: ["sc session add stores it there; someone must be logged in at its console."])
        }
        var server = mac ?? "localhost"
        if mac == nil {
            let port = try Network.freePort()
            let tunnel = Process()
            tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            tunnel.arguments = ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "LogLevel=ERROR", "-L", "\(port):localhost:5900", "\(user)@localhost"]
                + (tunnelEndsWithWindow ? ["sleep", "60"] : ["-N"])
            tunnel.standardInput = FileHandle.nullDevice
            try tunnel.run()
            // Ended once this user is done (`setUp`); a second or two to listen.
            try await Task.sleep(for: .seconds(2))
            guard tunnel.isRunning else { throw SCError("Couldn't make the SSH tunnel to this Mac's Screen Sharing (on port \(port)).") }
            server = "localhost:\(port)"
            tunnels.append(tunnel)
        }
        let allowed = CharacterSet.alphanumerics
        let address = "vnc://\(user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user):"
            + "\(password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password)@\(server)"
        let opened = try await Proc.collect("/usr/bin/osascript", ["-"], input: "open location \"\(address)\"\n")
        guard opened.succeeded else { throw SCError("Couldn't open Screen Sharing: \(opened.error)") }
    }

    /// Tunnels this run opened, ended when it's done.
    nonisolated(unsafe) static var tunnels: [Process] = []

    /// Waits until every tunnel has ended (its window closed), Return is
    /// pressed, or the task is cancelled (Ctrl-C), whichever comes first.
    /// Return is read on a thread of its own, left blocked if it never comes,
    /// so neither of the others waits on it.
    static func untilTunnelsEndOrReturn() async {
        let once = Once()
        let open = tunnels
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.set(continuation)
                let remaining = Countdown(open.count)
                for tunnel in open {
                    tunnel.terminationHandler = { _ in if remaining.decrement() { once.resume() } }
                    if !tunnel.isRunning, remaining.decrement() { once.resume() }
                }
                if open.isEmpty { once.resume() }
                Thread.detachNewThread {
                    _ = readLine()
                    once.resume()
                }
            }
        } onCancel: {
            once.resume()
        }
    }

    /// Resumes a continuation exactly once, from whichever caller is first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false
        func set(_ continuation: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock {
                if done { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        func resume() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                if done { return nil }
                done = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    /// Counts tunnels down to none, each counted once.
    private final class Countdown: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(_ count: Int) { left = count }
        /// Whether this was the last.
        func decrement() -> Bool { lock.withLock { left -= 1; return left == 0 } }
    }
}

extension Remote {
    /// Whether a command, once finished here or on another Mac, is followed
    /// here by `session setup`: `session add` is, unless `--no-setup`, as
    /// setting up opens Screen Sharing where the person is.
    static func followedBySetup(_ arguments: [String]) -> Bool {
        Array(arguments.prefix(2)) == ["session", "add"] && !arguments.contains("--no-setup")
    }

    /// What runs here once a command has finished, on `remote` (`--on`'s
    /// value) or here: `session add` sets up the test users it made or
    /// checked, by name, read back from the Mac it ran on
    /// (`SessionPool.justAddedFile`); nothing when it made none.
    static func followUp(after arguments: [String], on remote: String?) async throws -> [String]? {
        guard followedBySetup(arguments) else { return nil }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let users = try await SessionSetupCommand.addedLast(on: remote.map { parse($0, localRoot: cwd).host })
        guard !users.isEmpty else { return nil }
        let next = ["session", "setup"] + users
        TTY.write("▸ Now setting up the test users session add made or checked: sc \(next.joined(separator: " "))"
                  + (remote.map { " --on \($0)" } ?? "") + "\n")
        return next
    }

    /// Commands that take `--on` but run here and reach the other Mac
    /// themselves: `session setup` opens Screen Sharing on this Mac,
    /// `session screenshot` brings its picture back here, and `session view`
    /// opens its Screen Sharing window here.
    static func runsHere(_ arguments: [String]) -> Bool {
        arguments.first == "session" && ["setup", "screenshot", "view"].contains(arguments.dropFirst().first)
    }
}
