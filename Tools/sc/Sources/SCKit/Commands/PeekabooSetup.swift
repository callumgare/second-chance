import ArgumentParser
import Foundation

/// Peekaboo in a Mac's test sessions: installed if it isn't, its bridge
/// started in each, and the person walked through the two grants macOS won't
/// let a script give (Screen Recording and Accessibility live in the system's
/// TCC database, behind SIP). See docs/dev-cli.md#peekaboo-in-test-sessions.
struct SessionSetupPeekabooCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-peekaboo",
        abstract: "Set Peekaboo up in a Mac's test sessions, opening Screen Sharing on each for you to grant it.",
        discussion: """
        Run it on the Mac you're at, naming the test Mac with --mac (not --on: \
        the Screen Sharing window opens here). For each test user (or the one \
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

    @Option(help: ArgumentHelp("The test Mac.", valueName: "host"))
    var mac: String

    @Argument(help: "One test user. Default: every one in that Mac's pool.")
    var user: String?

    static let version = "4.9.7"
    static let appZipSHA256 = "ad87379580bdc9a2d96a62f1d3db7545b18306f8fcd96d1b50b4eee033959ed0"
    static let cliSHA256 = "8a4136b9efd4c3a5591840375b024009a3cfb1b5fe994f62268cc755fb37744c"
    static let bridgeLabel = "boo.peekaboo.bridge-host"

    func run() async throws {
        let session = try Session.start(global)
        let target = Remote.parse(mac, localRoot: session.repo.root)
        let host = target.host
        try await install(on: host, ui: session.ui)
        let pool = try await ssh(host, "cat \(SessionPool.file.path) 2>/dev/null").output
        let users = user.map { [$0] } ?? SessionPool.users(fromPool: pool)
        guard !users.isEmpty else { throw SCError("\(host) has no test sessions.", hints: ["Add some there: sc session add"]) }
        for user in users {
            try await setUp(user, on: target, ui: session.ui)
        }
        session.ui.success("Peekaboo is set up in \(users.count == 1 ? users[0] : "\(users.count) test sessions") on \(host).")
    }

    // MARK: Installing

    /// Peekaboo.app in /Applications and its CLI, from the release, checked
    /// against the release's checksums, unless they're there.
    private func install(on host: String, ui: UI) async throws {
        let base = "https://github.com/openclaw/Peekaboo/releases/download/v\(Self.version)"
        let script = """
        set -eu
        cli=""
        for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(Self.sharedCLI); do [ -x "$c" ] && cli=$c && break; done
        if [ -d /Applications/Peekaboo.app ] && [ -n "$cli" ]; then echo "present $cli"; exit 0; fi
        work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work"
        if [ ! -d /Applications/Peekaboo.app ]; then
          curl -fsSL -o app.zip "\(base)/Peekaboo-\(Self.version).app.zip"
          echo "\(Self.appZipSHA256)  app.zip" | shasum -a 256 -c - >/dev/null
          ditto -x -k app.zip app && spctl -a -vv app/Peekaboo.app 2>&1 | grep -q accepted
          ditto app/Peekaboo.app /Applications/Peekaboo.app
          echo "installed /Applications/Peekaboo.app"
        fi
        if [ -z "$cli" ]; then
          curl -fsSL -o cli.tgz "\(base)/peekaboo-macos-universal.tar.gz"
          echo "\(Self.cliSHA256)  cli.tgz" | shasum -a 256 -c - >/dev/null
          mkdir cli && tar -xzf cli.tgz -C cli
          found=$(find cli -type f -name peekaboo -perm -u+x | head -1)
          mkdir -p "$(dirname \(Self.sharedCLI))" && cp "$found" \(Self.sharedCLI) && chmod 755 \(Self.sharedCLI)
          echo "installed \(Self.sharedCLI)"
        fi
        """
        let result = try await ssh(host, "bash -s", input: script)
        guard result.succeeded else {
            throw SCError("Couldn't install Peekaboo \(Self.version) on \(host): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["It downloads from GitHub and needs /Applications writable by the user sc logs in as there."])
        }
        for line in result.output.split(separator: "\n") where line.hasPrefix("installed") { ui.detail("\(host): \(line)") }
    }

    /// Where the CLI goes when Homebrew's isn't there: readable by every user.
    static let sharedCLI = "/Users/Shared/second-chance/bin/peekaboo"

    // MARK: One user

    private func setUp(_ user: String, on target: Remote.Target, ui: UI) async throws {
        let host = target.host
        let destination = "\(user)@\(host)"
        let started = try await ssh(destination, "bash -s", input: Self.bridgeScript)
        guard started.succeeded else {
            throw SCError("Couldn't start Peekaboo's bridge for \(user) on \(host): \(started.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["Is \(user) logged in? sc --on \(host) session list"])
        }
        var missing = try await missingGrants(destination)
        if missing.isEmpty {
            ui.detail("\(host)/\(user): Peekaboo already has its grants.")
            return
        }
        ui.line("\(host)/\(user): Peekaboo needs \(missing.joined(separator: " and ")).")
        try await openPane(for: missing[0], destination)
        try await openScreenSharing(user, target)
        ui.line("In the Screen Sharing window (choose \"Log in as yourself\" if asked), turn Peekaboo on in "
                + "\(missing[0]); macOS asks for an admin's name and password. Waiting up to 15 minutes…")
        var shown = missing[0]
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            let now = try await missingGrants(destination)
            if now.isEmpty { break }
            if now.count < missing.count {
                // A new grant takes effect when the app restarts, as System Settings says.
                _ = try? await ssh(destination, "launchctl kickstart -k gui/$(id -u)/\(Self.bridgeLabel)")
            }
            if now[0] != shown {
                shown = now[0]
                try await openPane(for: shown, destination)
                ui.line("Now \(shown): turn Peekaboo on there too.")
            }
            missing = now
        }
        missing = try await missingGrants(destination)
        guard missing.isEmpty else {
            throw SCError("\(host)/\(user)'s Peekaboo still lacks \(missing.joined(separator: " and ")) after 15 minutes.",
                          hints: ["Run it again for that user: sc session setup-peekaboo \(user) --mac \(host)"])
        }
        ui.detail("\(host)/\(user): Peekaboo has its grants. You can close that Screen Sharing window.")
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
    /// over SSH, so it's read in the GUI session, comes back over SSH through
    /// a pipe, and goes to Screen Sharing by AppleScript, not a command line
    /// any process here could read. It's never written anywhere.
    private func openScreenSharing(_ user: String, _ target: Remote.Target) async throws {
        let script = Self.inGUISession(["/usr/bin/security", "find-generic-password", "-s", SessionPool.keychainService, "-a", user, "-w"])
        let result = try await ssh(target.host, "bash -s", input: script)
        let password = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !password.isEmpty, !password.contains("\n") else {
            throw SCError("Couldn't read \(user)'s password from \(target.host)'s keychain.",
                          hints: ["sc session add stores it there; someone must be logged in at \(target.host)'s console."])
        }
        let allowed = CharacterSet.alphanumerics
        let address = "vnc://\(user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user):"
            + "\(password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password)@\(target.host)"
        let opened = try await Proc.collect("/usr/bin/osascript", ["-"], input: "open location \"\(address)\"\n")
        guard opened.succeeded else { throw SCError("Couldn't open Screen Sharing: \(opened.error)") }
    }

    private func ssh(_ destination: String, _ command: String, input: String? = nil) async throws -> Proc.Collected {
        try await Proc.collect("/usr/bin/ssh", ["-o", "BatchMode=yes", destination, command], input: input)
    }
}
