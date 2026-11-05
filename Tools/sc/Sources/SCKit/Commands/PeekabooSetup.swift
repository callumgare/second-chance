import ArgumentParser
import Foundation
import WrappBuilder

/// Peekaboo in a Mac's test sessions: installed if it isn't, its bridge
/// started in each, and the person walked through the two grants macOS won't
/// let a script give (Screen Recording and Accessibility live in the system's
/// TCC database, behind SIP). See docs/dev-cli.md#peekaboo-in-test-sessions.
/// `sc session setup`'s Peekaboo task.
enum PeekabooSetup {
    static let version = "4.9.7"
    static let appZipSHA256 = "ad87379580bdc9a2d96a62f1d3db7545b18306f8fcd96d1b50b4eee033959ed0"
    static let cliSHA256 = "8a4136b9efd4c3a5591840375b024009a3cfb1b5fe994f62268cc755fb37744c"
    static let bridgeLabel = "boo.peekaboo.bridge-host"

    /// Set Peekaboo up in `users` (every test user in the pool when nil) on
    /// `mac` (this Mac when nil).
    static func run(users given: [String]?, on mac: String?, session: Session) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        let present = try await session.ui.progressStep("Checking whether Peekaboo is installed on \(host)") { _ in
            try await TestSessionAccess.asConsoleUser(mac, "bash -s", input: Self.presentScript).output
        }
        for part in Self.parts where !present.contains(part.marker) {
            try await session.ui.progressStep("Downloading and installing \(part.name) (\(part.megabytes) MB) on \(host)",
                                              success: "Installed \(part.name) on \(host)") { _ in
                try await install(part, on: mac)
            }
        }
        let users: [String]
        if let given, !given.isEmpty {
            users = given
        } else {
            let pool = try await session.ui.progressStep("Reading the list of test accounts on \(host)") { _ in
                try await TestSessionAccess.asConsoleUser(mac, "cat \(SessionPool.file.path) 2>/dev/null").output
            }
            users = SessionPool.users(fromPool: pool)
        }
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
    for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(sharedCLI); do [ -x "$c" ] && "$c" --version >/dev/null 2>&1 && echo cli && break; done
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
            # The whole folder: the tool loads a Swift library beside it.
            mkdir -p "$(dirname \(sharedCLI))" && cp "$(dirname "$found")"/* "$(dirname \(sharedCLI))"/ && chmod 755 \(sharedCLI)
            \(sharedCLI) --version >/dev/null
            """),
        ]
    }

    /// One part from the release, checked against the release's checksums.
    private static func install(_ part: Part, on mac: String?) async throws {
        let script = "set -eu\nwork=$(mktemp -d); trap 'rm -rf \"$work\"' EXIT; cd \"$work\"\n" + part.script
        let result = try await TestSessionAccess.asConsoleUser(mac, "bash -s", input: script)
        guard result.succeeded else {
            throw SCError("Couldn't install \(part.name) \(Self.version) on \(mac ?? "this Mac"): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["A 5xx from GitHub passes: run it again in a minute.",
                                  "It needs /Applications writable by " + (mac.map { "the user sc logs in as on \($0)" } ?? "you") + "."])
        }
    }

    /// Where the CLI goes when Homebrew's isn't there: readable by every user.
    static let sharedCLI = SharedFolders.root.appendingPathComponent("bin/peekaboo").path

    // MARK: One user

    private static func setUp(_ user: String, on mac: String?, ui: UI) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        let destination = "\(user)@\(mac ?? "localhost")"
        defer {
            TestSessionAccess.tunnels.forEach { $0.terminate() }
            TestSessionAccess.tunnels.removeAll()
        }
        if mac == nil { try await letThisMacIn(user, ui: ui) }
        var missing = try await ui.progressStep("Starting Peekaboo's background helper in \(host)/\(user) and checking its permissions") { _ in
            let started = try await TestSessionAccess.ssh(destination, "bash -s", input: Self.bridgeScript)
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
            try await TestSessionAccess.openScreenSharing(user, on: mac)
        }
        ui.line("In the Screen Sharing window (choose \"Log in as yourself\" if asked), turn Peekaboo on in \(missing[0]). "
                + "macOS asks for an admin's name and password.")
        missing = try await ui.progressStep("Waiting for Peekaboo's grants in \(host)/\(user) (up to 15 minutes)",
                                            success: "\(host)/\(user): Peekaboo has its grants. You can close that Screen Sharing window.") { update in
            var missing = missing
            var shown = missing[0]
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(5))
                // A grant takes effect only when the app starts again, as
                // System Settings says, so the bridge restarts before each look.
                _ = try? await TestSessionAccess.ssh(destination, "launchctl kickstart -k gui/$(id -u)/\(Self.bridgeLabel); sleep 2")
                let now = try await missingGrants(destination)
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
                          hints: ["Run it again for that user: sc session setup --only peekaboo \(user)" + (mac.map { " --on \($0)" } ?? "")])
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
    private static func missingGrants(_ destination: String) async throws -> [String] {
        let command = "cli=; for c in /opt/homebrew/bin/peekaboo /usr/local/bin/peekaboo \(Self.sharedCLI); do [ -x $c ] && cli=$c && break; done; "
            + "PEEKABOO_BRIDGE_SOCKET=\"$HOME/Library/Application Support/Peekaboo/bridge.sock\" $cli permissions --json"
        let result = try await TestSessionAccess.ssh(destination, "bash -c \(Remote.quote(command))")
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
    private static func openPane(for grant: String, _ destination: String) async throws {
        let anchor = grant == "Accessibility" ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        let url = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        _ = try await TestSessionAccess.ssh(destination, "bash -s", input: TestSessionAccess.inGUISession(["/usr/bin/open", url]))
    }

    /// This Mac's test sessions are reached over SSH too, which needs this
    /// Mac's own keys in each test user's authorized keys: `session add`
    /// puts them there (`--install-keys` for users made before it did).
    private static func letThisMacIn(_ user: String, ui: UI) async throws {
        let reachable = try await ui.progressStep("Checking this Mac can reach \(user) over SSH") { _ in
            try await TestSessionAccess.ssh("\(user)@localhost", "true").succeeded
        }
        guard reachable else {
            throw SCError("\(user) doesn't let this Mac in over SSH, so Peekaboo can't be set up in it from here.",
                          hints: ["Give this Mac's test users its keys (sudo asks for your password): ./sc session add --install-keys",
                                  "Is Remote Login on? System Settings → General → Sharing."])
        }
    }

}
