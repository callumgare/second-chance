import Foundation

/// `sc session setup`'s audio task: SC Audio Tap (`AudioTapApp`), which
/// `sc puppet audio` listens through, installed in each test session and the
/// person walked through its system-audio permission, which, like Peekaboo's
/// grants, macOS won't let a script give. The tap is built and signed here,
/// as `puppet start` sends it in a runtime copy, and installed with the same
/// stamp, so `puppet audio` keeps it and the permission given to it. See
/// docs/dev-cli.md#puppet-sessions.
enum AudioTapSetup {
    /// Set the tap up in `users` (every test user in the pool when nil) on
    /// `mac` (this Mac when nil).
    static func run(users given: [String]?, on mac: String?, session: Session) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        let signer = try await AudioTapApp.ensure(repo: session.repo.root, ui: session.ui)
        guard let stamp = try? String(contentsOf: AudioTapApp.stampFile, encoding: .utf8) else {
            throw SCError("\(AudioTapApp.name) was built, but its stamp (\(AudioTapApp.stampFile.path)) can't be read.")
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
        if signer == "ad hoc" {
            session.ui.warning("\(AudioTapApp.name) is signed ad hoc here, so a permission given to it lasts only until it's rebuilt.")
        }
        for user in users {
            try await setUp(user, on: mac, stamp: stamp, ui: session.ui)
        }
        session.ui.success("\(AudioTapApp.name) is set up in \(users.count == 1 ? users[0] : "\(users.count) test sessions") on \(host).")
    }

    /// The tap's folder in a test user's home, for their shell: `~/` left bare.
    static let remoteFolder = "~/Library/Application\\ Support/SecondChance/sc-audio-tap"

    /// The tap's executable there, as a program to run in their GUI session.
    static func remoteExecutable(home: String) -> String {
        "\(home)/Library/Application Support/SecondChance/sc-audio-tap/\(AudioTapApp.name).app/Contents/MacOS/sc-audio-tap"
    }

    private static func setUp(_ user: String, on mac: String?, stamp: String, ui: UI) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        let destination = "\(user)@\(mac ?? "localhost")"
        defer {
            TestSessionAccess.tunnels.forEach { $0.terminate() }
            TestSessionAccess.tunnels.removeAll()
        }
        let home = try await ui.progressStep("Installing \(AudioTapApp.name) in \(host)/\(user)") { _ in
            try await install(on: destination, user: user, host: host, stamp: stamp)
        }
        let executable = remoteExecutable(home: home)
        if try await permission(executable, destination) == "authorized" {
            ui.detail("\(host)/\(user): \(AudioTapApp.name) already has its permission.")
            return
        }
        try await ui.progressStep("Opening Screen Sharing into \(host)/\(user)") { _ in
            try await TestSessionAccess.openScreenSharing(user, on: mac)
        }
        ui.line("In the Screen Sharing window (choose \"Log in as yourself\" if asked), click Allow when macOS asks whether "
                + "\(AudioTapApp.name) may record system audio.")
        // Puts macOS's prompt on that session's screen, and waits a minute for an answer.
        let asked = try await ui.progressStep("Asking macOS for \(AudioTapApp.name)'s permission in \(host)/\(user)") { _ in
            try await TestSessionAccess.ssh(destination, "bash -s", input: TestSessionAccess.inGUISession([executable, "request"], timeout: 75))
        }
        if Self.permission(fromOutput: asked.output) == "authorized" {
            ui.success("\(host)/\(user): \(AudioTapApp.name) has its permission. You can close that Screen Sharing window.")
            return
        }
        _ = try? await TestSessionAccess.ssh(destination, "bash -s", input: TestSessionAccess.inGUISession(["/usr/bin/open", Self.paneURL]))
        ui.line("Or in System Settings, which is open there at Privacy & Security › Screen & System Audio Recording, turn "
                + "\(AudioTapApp.name) on under \"System Audio Recording Only\". macOS asks for an admin's name and password.")
        let granted = try await ui.progressStep("Waiting for \(AudioTapApp.name)'s permission in \(host)/\(user) (up to 15 minutes)",
                                                success: "\(host)/\(user): \(AudioTapApp.name) has its permission. You can close that Screen Sharing window.") { update in
            let deadline = Date().addingTimeInterval(900)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(5))
                if try await permission(executable, destination) == "authorized" { return true }
                update("Waiting for you to allow \(AudioTapApp.name) in \(host)/\(user)'s session")
            }
            return false
        }
        guard granted else {
            throw SCError("\(host)/\(user)'s \(AudioTapApp.name) still has no permission to record system audio after 15 minutes.",
                          hints: ["Run it again for that user: sc session setup --task audio \(user)" + (mac.map { " --on \($0)" } ?? "")])
        }
    }

    /// The tap and its stamp copied into the user's folder, unless the same
    /// build is there already; returns the user's home.
    private static func install(on destination: String, user: String, host: String, stamp: String) async throws -> String {
        let probe = try await TestSessionAccess.ssh(destination, "echo \"$HOME\"; cat \(remoteFolder)/stamp 2>/dev/null || true")
        guard probe.succeeded, let home = probe.output.split(separator: "\n").first.map(String.init), home.hasPrefix("/") else {
            throw SCError("Couldn't reach \(user) on \(host) over SSH: \(probe.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["Is \(user) logged in, and does it let this Mac in? sc session list" + (host == ScreenLease.shortHostName() ? "" : " --on \(host)")])
        }
        let installed = probe.output.split(separator: "\n").dropFirst().first.map(String.init)
        if installed == stamp.trimmingCharacters(in: .whitespacesAndNewlines) { return home }
        // tar keeps the bundle as signed; the old app goes first, as a copy
        // over it would leave files a new build dropped.
        let unpack = "mkdir -p \(remoteFolder) && cd \(remoteFolder) && rm -rf '\(AudioTapApp.name).app' && tar -xf -"
        let pipeline = "tar -C \(Remote.quote(AudioTapApp.folder.path)) -cf - \(Remote.quote("\(AudioTapApp.name).app")) stamp"
            + " | /usr/bin/ssh -o BatchMode=yes \(Remote.quote(destination)) \(Remote.quote(unpack))"
        let copied = try await Proc.collect("/bin/bash", ["-c", pipeline])
        guard copied.succeeded else {
            throw SCError("Couldn't copy \(AudioTapApp.name) to \(user) on \(host): \(copied.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return home
    }

    /// The tap's own answer, asked in the user's GUI session: TCC goes by
    /// the process responsible for the asker, which over SSH would be SSH's.
    private static func permission(_ executable: String, _ destination: String) async throws -> String {
        let result = try await TestSessionAccess.ssh(destination, "bash -s", input: TestSessionAccess.inGUISession([executable, "check"]))
        return Self.permission(fromOutput: result.output)
    }

    /// `authorized`, `denied` or `unknown` from the tap's `permission <state>`
    /// line; `unknown` when there's none.
    static func permission(fromOutput output: String) -> String {
        output.split(separator: "\n").last { $0.hasPrefix("permission ") }.map { String($0.dropFirst("permission ".count)) } ?? "unknown"
    }

    /// System Settings at Screen & System Audio Recording, whose "System
    /// Audio Recording Only" list is where the tap is turned on.
    static let paneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
