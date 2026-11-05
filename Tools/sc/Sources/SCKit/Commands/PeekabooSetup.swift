import ArgumentParser
import Foundation
import WrappBuilder

/// Peekaboo in a Mac's test sessions: installed if it isn't, its bridge
/// started in each, and the person walked through the two grants macOS won't
/// let a script give (Screen Recording and Accessibility live in the system's
/// TCC database, behind SIP). See docs/dev-cli.md#peekaboo-in-test-sessions.
struct SessionSetupPeekabooCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-peekaboo",
        abstract: "Set Peekaboo up in a Mac's test sessions, opening Screen Sharing on each for you to grant it.",
        discussion: """
        Run it on the Mac you're at. With --on it sets up that Mac's test \
        sessions, reaching them itself (the Screen Sharing window opens here); \
        without, this Mac's. For each test user (or the one \
        named) it installs Peekaboo on that Mac if it's missing, starts \
        Peekaboo's bridge in the user's session, and if it lacks Screen \
        Recording or Accessibility opens that pane there and a Screen Sharing \
        window into the session here, logged in with the password from the test \
        Mac's keychain (passed straight through, never saved). Turn Peekaboo on \
        in the pane (macOS asks for an admin's password), and it moves on once \
        the grant shows.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "One test user. Default: every one in that Mac's pool.")
    var user: String?

    static let version = "4.9.7"
    static let appZipSHA256 = "ad87379580bdc9a2d96a62f1d3db7545b18306f8fcd96d1b50b4eee033959ed0"
    static let cliSHA256 = "8a4136b9efd4c3a5591840375b024009a3cfb1b5fe994f62268cc755fb37744c"
    static let bridgeLabel = "boo.peekaboo.bridge-host"

    func run() async throws {
        let session = try Session.start(global)
        // nil: this Mac, whose own steps run here without SSH.
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        let host = mac ?? ScreenLease.shortHostName()
        let present = try await session.ui.progressStep("Checking whether Peekaboo is installed on \(host)") { _ in
            try await asConsoleUser(mac, "bash -s", input: Self.presentScript).output
        }
        for part in Self.parts where !present.contains(part.marker) {
            try await session.ui.progressStep("Downloading and installing \(part.name) (\(part.megabytes) MB) on \(host)",
                                              success: "Installed \(part.name) on \(host)") { _ in
                try await install(part, on: mac)
            }
        }
        let pool = try await session.ui.progressStep("Reading the list of test accounts on \(host)") { _ in
            try await asConsoleUser(mac, "cat \(SessionPool.file.path) 2>/dev/null").output
        }
        let users = user.map { [$0] } ?? SessionPool.users(fromPool: pool)
        guard !users.isEmpty else { throw SCError("\(host) has no test sessions.", hints: ["Add some there: sc session add"]) }
        for user in users {
            try await setUp(user, on: mac, ui: session.ui)
        }
        session.ui.success("Peekaboo is set up in \(users.count == 1 ? users[0] : "\(users.count) test sessions") on \(host).")
    }

    // MARK: Installing

    /// Prints `app` and `cli` for the parts that are there.
    static let presentScript = """
    [ -d /Applications/Peekaboo.app ] && echo app
    for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(sharedCLI); do [ -x "$c" ] && echo cli && break; done
    true
    """

    struct Part: Sendable {
        let name: String
        let marker: String
        let megabytes: Int
        let script: String
    }

    static var parts: [Part] {
        let base = "https://github.com/openclaw/Peekaboo/releases/download/v\(version)"
        let fetch = "curl -fsSL --retry 4 --retry-all-errors --retry-delay 3"
        return [
            Part(name: "Peekaboo.app", marker: "app", megabytes: 41, script: """
            \(fetch) -o app.zip "\(base)/Peekaboo-\(version).app.zip"
            echo "\(appZipSHA256)  app.zip" | shasum -a 256 -c - >/dev/null
            ditto -x -k app.zip app && spctl -a -vv app/Peekaboo.app 2>&1 | grep -q accepted
            ditto app/Peekaboo.app /Applications/Peekaboo.app
            """),
            Part(name: "Peekaboo's command-line tool", marker: "cli", megabytes: 30, script: """
            \(fetch) -o cli.tgz "\(base)/peekaboo-macos-universal.tar.gz"
            echo "\(cliSHA256)  cli.tgz" | shasum -a 256 -c - >/dev/null
            mkdir cli && tar -xzf cli.tgz -C cli
            found=$(find cli -type f -name peekaboo -perm -u+x | head -1)
            mkdir -p "$(dirname \(sharedCLI))" && cp "$found" \(sharedCLI) && chmod 755 \(sharedCLI)
            """),
        ]
    }

    /// One part from the release, checked against the release's checksums.
    private func install(_ part: Part, on mac: String?) async throws {
        let script = "set -eu\nwork=$(mktemp -d); trap 'rm -rf \"$work\"' EXIT; cd \"$work\"\n" + part.script
        let result = try await asConsoleUser(mac, "bash -s", input: script)
        guard result.succeeded else {
            throw SCError("Couldn't install \(part.name) \(Self.version) on \(mac ?? "this Mac"): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["A 5xx from GitHub passes: run it again in a minute.",
                                  "It needs /Applications writable by " + (mac.map { "the user sc logs in as on \($0)" } ?? "you") + "."])
        }
    }

    /// Where the CLI goes when Homebrew's isn't there: readable by every user.
    static let sharedCLI = SharedFolders.root.appendingPathComponent("bin/peekaboo").path

    // MARK: One user

    private func setUp(_ user: String, on mac: String?, ui: UI) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        let destination = "\(user)@\(mac ?? "localhost")"
        defer {
            Self.tunnels.forEach { $0.terminate() }
            Self.tunnels.removeAll()
        }
        if mac == nil { try await letThisMacIn(user, ui: ui) }
        var missing = try await ui.progressStep("Starting Peekaboo's background helper in \(host)/\(user) and checking its permissions") { _ in
            let started = try await ssh(destination, "bash -s", input: Self.bridgeScript)
            guard started.succeeded else {
                throw SCError("Couldn't start Peekaboo's bridge for \(user) on \(host): \(started.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                              hints: ["Is \(user) logged in? sc" + (mac.map { " --on \($0)" } ?? "") + " session list"])
            }
            return try await missingGrants(destination)
        }
        if missing.isEmpty {
            ui.detail("\(host)/\(user): Peekaboo already has its grants.")
            return
        }
        try await ui.progressStep("Opening \(missing[0]) in \(host)/\(user)'s System Settings, and Screen Sharing here") { _ in
            try await openPane(for: missing[0], destination)
            try await openScreenSharing(user, on: mac)
        }
        ui.line("In the Screen Sharing window (choose \"Log in as yourself\" if asked), turn Peekaboo on in \(missing[0]). "
                + "macOS asks for an admin's name and password.")
        missing = try await ui.progressStep("Waiting for Peekaboo's grants in \(host)/\(user) (up to 15 minutes)",
                                            success: "\(host)/\(user): Peekaboo has its grants. You can close that Screen Sharing window.") { update in
            var missing = missing
            var shown = missing[0]
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(3))
                let now = try await missingGrants(destination)
                if now.count < missing.count {
                    // A new grant takes effect when the app restarts, as System Settings says.
                    _ = try? await ssh(destination, "launchctl kickstart -k gui/$(id -u)/\(Self.bridgeLabel)")
                }
                missing = now
                if now.isEmpty { return now }
                if now[0] != shown {
                    shown = now[0]
                    try await openPane(for: shown, destination)
                }
                update("Waiting for you to turn Peekaboo on in \(shown), in \(host)/\(user)'s System Settings")
            }
            return missing
        }
        guard missing.isEmpty else {
            throw SCError("\(host)/\(user)'s Peekaboo still lacks \(missing.joined(separator: " and ")) after 15 minutes.",
                          hints: ["Run it again for that user: sc session setup-peekaboo \(user)" + (mac.map { " --on \($0)" } ?? "")])
        }
    }

    /// The bridge as a LaunchAgent in the user's GUI session, as on the
    /// console user's: Peekaboo's commands over SSH reach it through its socket.
    static let bridgeScript = """
    set -eu
    plist=~/Library/LaunchAgents/\(bridgeLabel).plist
    mkdir -p ~/Library/LaunchAgents
    cat > "$plist" <<P
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(bridgeLabel)</string>
    <key>ProgramArguments</key><array><string>/Applications/Peekaboo.app/Contents/MacOS/Peekaboo</string><string>--background-bridge-host</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    </dict></plist>
    P
    launchctl print gui/$(id -u)/\(bridgeLabel) >/dev/null 2>&1 || launchctl bootstrap gui/$(id -u) "$plist"
    # Bootstrapped over SSH, launchd loads the job but doesn't run it at load.
    launchctl kickstart gui/$(id -u)/\(bridgeLabel) 2>/dev/null || true
    for i in $(seq 1 20); do [ -S ~/Library/Application\\ Support/Peekaboo/bridge.sock ] && exit 0; sleep 1; done
    echo "the bridge's socket didn't appear" >&2; exit 1
    """

    /// The required grants Peekaboo says it lacks, through the user's bridge.
    private func missingGrants(_ destination: String) async throws -> [String] {
        let command = "cli=; for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(Self.sharedCLI); do [ -x $c ] && cli=$c && break; done; "
            + "PEEKABOO_BRIDGE_SOCKET=\"$HOME/Library/Application Support/Peekaboo/bridge.sock\" $cli permissions --json"
        let result = try await ssh(destination, "bash -c \(Remote.quote(command))")
        return Self.missing(fromPermissionsJSON: Data(result.output.utf8))
    }

    static func missing(fromPermissionsJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = (root["data"] as? [String: Any])?["permissions"] as? [[String: Any]] else {
            return ["Screen Recording", "Accessibility"]
        }
        return permissions.filter { ($0["isRequired"] as? Bool) == true && ($0["isGranted"] as? Bool) != true }
            .compactMap { $0["name"] as? String }
    }

    /// System Settings at the pane for `grant`, in the user's session.
    private func openPane(for grant: String, _ destination: String) async throws {
        let anchor = grant == "Accessibility" ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        let url = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        _ = try await ssh(destination, "bash -s", input: Self.inGUISession(["/usr/bin/open", url]))
    }

    /// A script that runs `arguments` once in the SSH user's GUI session, as
    /// a LaunchAgent (`open` or the keychain from SSH reach no GUI session),
    /// and streams its output back through a named pipe, so nothing it prints
    /// is written to disk.
    static func inGUISession(_ arguments: [String]) -> String {
        let program = arguments.map { "<string>\($0.replacingOccurrences(of: "&", with: "&amp;"))</string>" }.joined()
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
        <key>StandardOutPath</key><string>$dir/out</string><key>RunAtLoad</key><true/></dict></plist>
        P
        launchctl bootstrap gui/$(id -u) "$dir/job.plist"
        perl -e 'alarm 30; exec "cat", @ARGV' "$dir/out"
        """
    }

    /// A Screen Sharing window here into the user's session, logged in with
    /// the password from the test Mac's keychain. That keychain is locked
    /// over SSH, so it's read in the GUI session, comes back through a pipe,
    /// and goes to Screen Sharing by AppleScript, not a command line any
    /// process here could read. It's never written anywhere. Screen Sharing
    /// won't connect a Mac to itself, so this Mac's sessions are reached
    /// through an SSH tunnel to its own Screen Sharing.
    private func openScreenSharing(_ user: String, on mac: String?) async throws {
        let script = Self.inGUISession(["/usr/bin/security", "find-generic-password", "-s", SessionPool.keychainService, "-a", user, "-w"])
        let result = try await asConsoleUser(mac, "bash -s", input: script)
        let password = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !password.isEmpty, !password.contains("\n") else {
            throw SCError("Couldn't read \(user)'s password from \(mac ?? "this Mac")'s keychain.",
                          hints: ["sc session add stores it there; someone must be logged in at its console."])
        }
        var server = mac ?? "localhost"
        if mac == nil {
            let port = 5901
            let tunnel = Process()
            tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            tunnel.arguments = ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-N", "-L", "\(port):localhost:5900", "\(user)@localhost"]
            tunnel.standardInput = FileHandle.nullDevice
            try tunnel.run()
            // Ended once this user is done (`setUp`); a second or two to listen.
            try await Task.sleep(for: .seconds(2))
            guard tunnel.isRunning else { throw SCError("Couldn't make the SSH tunnel to this Mac's Screen Sharing (is port \(port) in use?).") }
            server = "localhost:\(port)"
            Self.tunnels.append(tunnel)
        }
        let allowed = CharacterSet.alphanumerics
        let address = "vnc://\(user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user):"
            + "\(password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password)@\(server)"
        let opened = try await Proc.collect("/usr/bin/osascript", ["-"], input: "open location \"\(address)\"\n")
        guard opened.succeeded else { throw SCError("Couldn't open Screen Sharing: \(opened.error)") }
    }

    /// Tunnels this run opened, ended when it's done.
    nonisolated(unsafe) static var tunnels: [Process] = []

    /// This Mac's test sessions are reached over SSH too, which needs this
    /// Mac's own keys in each test user's authorized keys: `session add`
    /// puts them there (`--install-keys` for users made before it did).
    private func letThisMacIn(_ user: String, ui: UI) async throws {
        let reachable = try await ui.progressStep("Checking this Mac can reach \(user) over SSH") { _ in
            try await ssh("\(user)@localhost", "true").succeeded
        }
        guard reachable else {
            throw SCError("\(user) doesn't let this Mac in over SSH, so Peekaboo can't be set up in it from here.",
                          hints: ["Give this Mac's test users its keys (sudo asks for your password): ./sc session add --install-keys",
                                  "Is Remote Login on? System Settings → General → Sharing."])
        }
    }

    /// A command as the user sc runs as: here, or over SSH on `mac`.
    private func asConsoleUser(_ mac: String?, _ command: String, input: String? = nil) async throws -> Proc.Collected {
        if let mac { return try await ssh(mac, command, input: input) }
        return try await Proc.collect("/bin/bash", ["-c", command], input: input)
    }

    private func ssh(_ destination: String, _ command: String, input: String? = nil) async throws -> Proc.Collected {
        try await Proc.collect("/usr/bin/ssh", ["-o", "BatchMode=yes", destination, command], input: input)
    }
}

extension Remote {
    /// Commands that take `--on` but run here and reach the other Mac
    /// themselves: `session setup-peekaboo` opens Screen Sharing on this Mac,
    /// and `session screenshot` brings its picture back here.
    static func runsHere(_ arguments: [String]) -> Bool {
        arguments.first == "session" && ["setup-peekaboo", "screenshot"].contains(arguments.dropFirst().first)
    }
}

/// A Mac's whole screen, or a test session's, through Peekaboo there: what
/// no game window shows (a system prompt, an installer, the Finder).
struct SessionScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Picture a Mac's whole screen, or a test session's, through Peekaboo, and bring it back here.",
        discussion: """
        Takes it with that user's Peekaboo (`session setup-peekaboo` gives a test \
        session its grants), shrinks it to --max pixels across, and saves it here. \
        With --on, of that Mac; without, of this one. No user: the Mac's own \
        logged-in user's screen.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "A test user whose session to picture. Default: the user sc logs in as.")
    var user: String?

    @Option(help: ArgumentHelp("Where to save it here.", valueName: "png")) var out: String?
    @Option(help: "Its longest side, in pixels (cheap to look at).") var max: Int = 1600

    func run() async throws {
        let session = try Session.start(global)
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        let host = mac ?? ScreenLease.shortHostName()
        let name = user.map { "\(host)/\($0)" } ?? host
        let destination = user.map { "\($0)@\(mac ?? "localhost")" } ?? mac
        let remote = "/tmp/sc-screen-\(UUID().uuidString).png"
        let output = URL(fileURLWithPath: out ?? "screen-\(name.replacingOccurrences(of: "/", with: "-")).png")
        let command = "cli=; for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(SessionSetupPeekabooCommand.sharedCLI); "
            + "do [ -x $c ] && cli=$c && break; done; [ -n \"$cli\" ] || { echo 'Peekaboo is not installed' >&2; exit 3; }; "
            + "PEEKABOO_BRIDGE_SOCKET=\"$HOME/Library/Application Support/Peekaboo/bridge.sock\" $cli see --mode screen --no-elements "
            + "--path \(remote) >/dev/null && sips -Z \(max) \(remote) >/dev/null"
        try await session.ui.progressStep("Picturing \(name)'s screen with Peekaboo", success: "Saved \(name)'s screen to \(output.path)") { _ in
            let shell = destination.map { ["/usr/bin/ssh", "-o", "BatchMode=yes", $0, "bash -c \(Remote.quote(command))"] }
                ?? ["/bin/bash", "-c", command]
            let taken = try await Proc.collect(shell[0], Array(shell.dropFirst()))
            guard taken.succeeded else {
                throw SCError("Peekaboo couldn't picture \(name)'s screen: \(taken.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                              hints: ["Give it Peekaboo and its grants: sc session setup-peekaboo" + (user.map { " \($0)" } ?? "")
                                      + (mac.map { " --on \($0)" } ?? ""),
                                      "Is someone logged in there, and is the screen unlocked? sc" + (mac.map { " --on \($0)" } ?? "") + " session list"])
            }
            if let destination {
                let copied = try await Proc.collect("/usr/bin/scp", ["-q", "-o", "BatchMode=yes", "\(destination):\(remote)", output.path])
                _ = try? await Proc.collect("/usr/bin/ssh", ["-o", "BatchMode=yes", destination, "rm -f \(remote)"])
                guard copied.succeeded else { throw SCError("Couldn't copy the picture back: \(copied.error)") }
            } else {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: URL(fileURLWithPath: remote), to: output)
            }
        }
    }
}
