import ArgumentParser
import Foundation
import WrappBuilder

struct SessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Test sessions: background logins on a Mac that run games without its screen.",
        discussion: """
        Each test user in the Mac's pool (/Users/Shared/second-chance/pool) has \
        a GUI login of its own, kept logged in, unlocked and drawing by the \
        console user's keep-alive, so a game runs there while the person, or \
        another run, has the screen. Claim one, run in it with \
        sc --on <user>@<host>:<path>, and release it. Usually: \
        sc --on <host> session claim --purpose "…". See docs/dev-cli.md#test-sessions.
        """,
        subcommands: [SessionListCommand.self, SessionClaimCommand.self, SessionReleaseCommand.self,
                      SessionKeepAliveCommand.self, SessionAddCommand.self, SessionSetupPeekabooCommand.self,
                      SessionScreenshotCommand.self],
        defaultSubcommand: SessionListCommand.self
    )
}

struct SessionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the test sessions: logged in, locked, leased or free (the default)."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        let pool = SessionPool.users()
        guard !pool.isEmpty else {
            session.ui.detail("\(ScreenLease.shortHostName()) has no test sessions. Set some up: sc session add")
            return
        }
        for status in await SessionPool.statuses(users: pool) {
            session.ui.line("\(SessionPool.screenName(of: status.user)): \(status.summary)")
        }
    }
}

struct SessionClaimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim",
        abstract: "Lease a free test session (or the one named) for your runs.",
        discussion: """
        Leases its screen to you, as `sc lease take` would, so runs you start \
        there go ahead and anyone else's stop. Renew it by claiming it again; \
        `sc --on <user>@<host> lease expiring` warns before it runs out.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(name: .customLong("for"), help: ArgumentHelp("How long: 30m, 2h, 90s, or minutes (at most 8h).", valueName: "time"))
    var duration: String = "2h"

    @Argument(help: "A test user to claim. Default: the first free one.")
    var user: String?

    @Flag(help: "Also print the claim as one line of JSON (host, user, expires), for scripts such as a sharded run.")
    var json = false

    @Flag(help: "Claim a session you don't hold already, rather than renew one you do: for a run of its own beside your other work.")
    var new = false

    func validate() throws {
        if ScreenLease.parseDuration(duration) == nil {
            throw ValidationError("--for takes a time such as 30m, 2h or 90s, of at most 8 hours.")
        }
        if global.purpose == nil {
            throw ValidationError("Say what it's for with --purpose \"<text>\": it's what anyone it stops will see.")
        }
    }

    func run() async throws {
        let session = try Session.start(global)
        let statuses = await SessionPool.statuses()
        let holder = ScreenLease.currentHolder(repoRoot: session.repo.root, branch: await ScreenLease.branch(of: session.repo.root))
        let chosen: SessionPool.Status
        if let user {
            guard let status = statuses.first(where: { $0.user == user }) else {
                throw SCError("\(user) isn't one of \(ScreenLease.shortHostName())'s test sessions (\(statuses.map(\.user).joined(separator: ", "))).")
            }
            guard status.login != nil else {
                throw SCError("\(SessionPool.screenName(of: user)) isn't logged in.",
                              hints: ["The keep-alive logs it in: sc session keep-alive --install, in the console user's account."])
            }
            chosen = status
        } else {
            let renewable = new ? nil : statuses.first { $0.lease.map { $0.isTakenByHand && $0.holder.isSame(as: holder) } ?? false }
            guard let free = renewable ?? statuses.first(where: \.isFree) else {
                let lines = statuses.map { "\(SessionPool.screenName(of: $0.user)): \($0.summary)" }
                throw SCError("No test session on \(ScreenLease.shortHostName()) is free.\n" + lines.joined(separator: "\n"),
                              exitCode: ScreenLease.heldExitCode)
            }
            chosen = free
        }
        let seconds = ScreenLease.parseDuration(duration) ?? 7200
        let lease = try await ScreenLease.take(session, policy: global.leasePolicy, purpose: global.purpose,
                                               duration: seconds, user: chosen.user)
        let host = ScreenLease.shortHostName()
        let checkout = Self.homeRelative(session.repo.root.path)
        session.ui.line("Claimed \(host)/\(chosen.user) until \(lease.expires.map(ScreenLease.clock) ?? "?").")
        // Asked from this Mac (not through --on from another), it's reached
        // as localhost, and released here.
        let local = holder.host == host
        session.ui.detail("Run in it: sc --on \(chosen.user)@\(local ? "localhost" : host):\(checkout) <command>")
        session.ui.detail("Give it back: sc \(local ? "" : "--on \(host) ")session release \(chosen.user)")
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            let claim = ShardCoordinator.Claim(host: host, user: chosen.user, expires: lease.expires)
            FileHandle.standardOutput.write(try encoder.encode(claim) + Data("\n".utf8))
        }
    }

    static func homeRelative(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct SessionReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Give back a test session you claimed (default: every one you hold here)."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The test user to release.")
    var user: String?

    func run() async throws {
        let session = try Session.start(global)
        let holder = ScreenLease.currentHolder(repoRoot: session.repo.root, branch: await ScreenLease.branch(of: session.repo.root))
        let users = user.map { [$0] } ?? SessionPool.users().filter { candidate in
            ScreenLease.read(ScreenLease.file(for: candidate)).map { $0.isTakenByHand && $0.holder.isSame(as: holder) } ?? false
        }
        if users.isEmpty { session.ui.detail("You hold no test session on \(ScreenLease.shortHostName()).") }
        for user in users {
            let released = try await ScreenLease.releaseTaken(session, user: user)
            session.ui.detail(released ? "Released \(SessionPool.screenName(of: user))." : "\(SessionPool.screenName(of: user)) wasn't leased.")
        }
    }
}

struct SessionKeepAliveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep-alive",
        abstract: "Keep every test session logged in, unlocked and drawing (run in the console user's session).",
        discussion: """
        Holds a Screen Sharing connection into each test session, as a viewer \
        would: a session with none is locked and stops drawing OpenGL. It logs \
        a session in if it isn't, unlocks it when it locks, and reconnects when \
        the connection drops, reading the pool again every minute. Passwords \
        come from this user's keychain, which is locked over SSH, so it runs \
        as a LaunchAgent: --install sets that up.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Install it as this user's LaunchAgent, started at login and restarted if it stops.")
    var install = false

    @Flag(help: "Stop it and remove the LaunchAgent.")
    var uninstall = false

    static let label = "au.gare.callum.second-chance.session-keep-alive"
    static var plist: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var domain: String { "gui/\(getuid())" }

    /// Whether it's installed and launchd has it.
    static func isInstalled() async -> Bool {
        guard FileManager.default.fileExists(atPath: plist.path) else { return false }
        return (try? await Proc.collect("/bin/launchctl", ["print", "\(domain)/\(label)"]))?.succeeded ?? false
    }

    static func uninstall() async throws {
        _ = try await Proc.collect("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    /// Install the LaunchAgent and start it. Returns its log. It runs a copy
    /// of this sc, not the checkout's: every `--on` sync rebuilds that, and a
    /// sync that broke the build would stop the keep-alive coming back.
    static func install(repo: URL) async throws -> URL {
        _ = try await Proc.collect("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let copy = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/SecondChance/session-keep-alive/sc")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]), to: copy)
        let log = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/SecondChance/session-keep-alive.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [copy.path, "session", "keep-alive"],
            "WorkingDirectory": repo.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            // Not Background: logging test sessions in and unlocking them is
            // what every run there waits on, and on a loaded Mac a Background
            // job was starved for minutes in the login's key exchange.
            "ProcessType": "Standard",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
        // bootout returns before the old job has gone, and a bootstrap then is
        // refused: wait for it (a few seconds at most), and try twice.
        for _ in 0..<40 where (try? await Proc.collect("/bin/launchctl", ["print", "\(domain)/\(label)"]))?.succeeded == true {
            try await Task.sleep(for: .milliseconds(250))
        }
        var result = try await Proc.collect("/bin/launchctl", ["bootstrap", domain, plist.path])
        if !result.succeeded {
            try await Task.sleep(for: .seconds(2))
            result = try await Proc.collect("/bin/launchctl", ["bootstrap", domain, plist.path])
        }
        guard result.succeeded else {
            throw SCError("launchctl couldn't start the keep-alive: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))",
                          hints: ["It must be installed by the user logged in at the Mac's display."])
        }
        return log
    }

    func validate() throws {
        if install && uninstall { throw ValidationError("--install or --uninstall, not both.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        if uninstall {
            try await Self.uninstall()
            session.ui.detail("The keep-alive is stopped and removed. Test sessions lock once their connection goes.")
            return
        }
        if install {
            let log = try await Self.install(repo: session.repo.root)
            session.ui.detail("The keep-alive runs now and at every login. Its log: \(log.path)")
            return
        }
        try await SessionKeepAlive.run(users: SessionPool.users)
    }
}

/// The keep-alive's work: one task per test user, each connecting, unlocking
/// and refreshing, and starting again after a failure.
enum SessionKeepAlive {
    static func run(users: @escaping @Sendable () -> [String]) async throws {
        var tasks: [String: Task<Void, Never>] = [:]
        while !Task.isCancelled {
            let pool = Set(users())
            for user in pool where tasks[user] == nil {
                tasks[user] = Task.detached { await keep(user) }
            }
            for (user, task) in tasks where !pool.contains(user) {
                task.cancel()
                tasks[user] = nil
                say("\(user): left the pool, letting go")
            }
            if pool.isEmpty { say("The pool (\(SessionPool.file.path)) is empty: nothing to keep.") }
            try await Task.sleep(for: .seconds(60))
        }
    }

    static func keep(_ user: String) async {
        var wait = 5.0
        while !Task.isCancelled {
            do {
                let password = try await SessionPool.password(for: user)
                let connection = try ScreenSharingConnection(user: user, password: password)
                say("\(user): connected (\(connection.width)x\(connection.height))")
                wait = 5
                var checked = Date.distantPast
                let connected = Date()
                while !Task.isCancelled {
                    try connection.refresh()
                    if Date().timeIntervalSince(checked) >= 10 {
                        checked = Date()
                        let login = await SessionPool.logins().first(where: { $0.user == user })
                        // Logged out (as killing its Setup Assistant does), the
                        // connection stays up, showing the login window: only a
                        // new one logs the user in again. A fresh login takes a
                        // few seconds to show, so not straight after connecting.
                        if login == nil, Date().timeIntervalSince(connected) > 30 {
                            throw SCError("logged out; connecting again logs it back in")
                        }
                        if login?.locked == true {
                            say("\(user): locked, unlocking")
                            try connection.unlock(password: password)
                        }
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {
                return
            } catch {
                say("\(user): \(error.localizedDescription); again in \(Int(wait)) s")
                try? await Task.sleep(for: .seconds(wait))
                // A refused password retried too often could lock the account.
                wait = min(wait * 2, 600)
            }
        }
    }

    static func say(_ text: String) {
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        FileHandle.standardOutput.write(Data("\(stamp) \(text)\n".utf8))
    }
}

struct SessionAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Set this Mac up for test sessions: make test users and the installers store, start the keep-alive.",
        discussion: """
        Run it as the admin who uses the Mac's display, at the Mac or with \
        sc --on <host> session add from a terminal: it uses sudo, and keeps \
        each new user's password in this user's keychain (asking to unlock it \
        over SSH). It makes standard users named second-chance-testing-1, -2, … (or the \
        names given; an existing user whose password is in the keychain is \
        adopted), lets them in over SSH and Screen Sharing with this user's \
        authorized keys, and adds them to the pool. Then it makes the installers \
        store every user reads, if the Mac has none, and installs the keep-alive, which logs the new sessions in. Running it again \
        fixes whatever is missing. See docs/dev-cli.md#test-sessions.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Test users' short names. Default: the next free second-chance-testing-<n>.")
    var users: [String] = []

    @Option(help: "How many new ones to make. Default: one when the pool is empty, else none (the pool's are checked).")
    var count: Int?

    @Flag(help: "Give existing test users this user's authorized SSH keys too (new ones always get them).")
    var installKeys = false

    func validate() throws {
        for user in users where user.range(of: #"^[a-z][a-z0-9_-]{1,30}$"#, options: .regularExpression) == nil {
            throw ValidationError("\(user): a user's short name is lower-case letters, digits and hyphens, starting with a letter.")
        }
        if let count, !(1...9).contains(count) { throw ValidationError("--count is 1 to 9.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        var pool = SessionPool.users()
        let names = Self.names(given: users, count: count, pool: pool, taken: await SessionPool.existingUsers())
        try await Self.unlockKeychain(session)
        for user in names {
            try await add(user, session: session)
            if !pool.contains(user) { pool.append(user) }
        }
        try ScreenLease.makeFolder(SessionPool.folder)
        try (pool.joined(separator: "\n") + "\n").write(to: SessionPool.file, atomically: true, encoding: .utf8)
        chmod(SessionPool.file.path, 0o666)
        session.ui.detail("The pool: \(pool.joined(separator: ", ")).")

        session.ui.detail(try await SessionPool.makeInstallersStore(store: InstallersStore.defaultRoot))
        if await SessionKeepAliveCommand.isInstalled() {
            session.ui.detail("The keep-alive is running; it picks up new users within a minute.")
        } else {
            let log = try await SessionKeepAliveCommand.install(repo: session.repo.root)
            session.ui.detail("Started the keep-alive, which logs test sessions in and keeps them drawing. Its log: \(log.path)")
        }
        let host = ScreenLease.shortHostName()
        session.ui.success("\(names.map { "\(host)/\($0)" }.joined(separator: ", ")) ready.",
                           takeaways: ["See them: sc session",
                                       "Claim one: sc session claim --purpose \"…\"",
                                       "Run in it: sc --on <user>@\(host):<path> test integration <game>"])
    }

    /// Who to make or check: the names given; else `count` new ones; else,
    /// run again on a Mac that has a pool, the pool's own (so it fixes what's
    /// missing rather than making another); else one new one.
    static func names(given: [String], count: Int?, pool: [String], taken: Set<String>) -> [String] {
        if !given.isEmpty { return given }
        if let count { return SessionPool.nextNames(count, taken: taken) }
        return pool.isEmpty ? SessionPool.nextNames(1, taken: taken) : pool
    }

    private func add(_ user: String, session: Session) async throws {
        let created = getpwnam(user) == nil
        if !created {
            _ = try await SessionPool.password(for: user)
            session.ui.detail("\(user) exists and its password is in the keychain: adopting it.")
        } else {
            let password = Self.newPassword()
            let name = "Second Chance Test" + (user.last?.isNumber == true ? " " + String(user.reversed().prefix { $0.isNumber }.reversed()) : "")
            session.ui.detail("Creating \(user) (\(name)), a standard user. sudo may ask for your password.")
            try await sudo(["/usr/sbin/sysadminctl", "-addUser", user, "-fullName", name, "-password", password])
            let stored = try await Proc.collect("/usr/bin/security", ["add-generic-password", "-U", "-s", SessionPool.keychainService,
                                                                           "-a", user, "-w", password])
            guard stored.succeeded else {
                throw SCError("Created \(user), but couldn't keep its password in the keychain.",
                              hints: ["Set a new one and store it: sudo passwd \(user), then "
                                      + "security add-generic-password -s \(SessionPool.keychainService) -a \(user) -w"])
            }
            try await sudo(["/usr/sbin/createhomedir", "-c", "-u", user])
        }
        // A new user's first login otherwise stops in Setup Assistant, where
        // nothing of sc's can start (a LaunchAgent for the Aqua session never
        // runs), though the session counts as logged in. Seen-before settings
        // skip it; a session already stuck there is closed too, and the
        // keep-alive logs it in again.
        let stuck = try await Self.inSetupAssistant(user)
        if created || stuck {
            try await sudo(["-u", user, "/bin/bash", "-c", Self.setupAssistantDoneScript(build: Self.osVersion("-buildVersion"),
                                                                                         version: Self.osVersion("-productVersion"))])
            if stuck {
                session.ui.detail("\(user) was stuck in Setup Assistant: marked it done and logged the session out for the keep-alive to log in again.")
                try await sudo(["/usr/bin/pkill", "-u", user, "-x", "Setup Assistant"])
            }
        }
        // Each step only if it's missing, so running it again (or adopting a
        // user) asks for no password when nothing needs changing.
        for group in ["com.apple.access_ssh", "com.apple.access_screensharing"] {
            let found = try await Proc.collect("/usr/bin/dscl", [".", "-read", "/Groups/\(group)"])
            let member = try await Proc.collect("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", user, group])
            if found.succeeded, !member.succeeded {
                try await sudo(["/usr/sbin/dseditgroup", "-o", "edit", "-a", user, "-t", "user", group])
            }
        }
        // A user made just now gets this user's keys; one adopted keeps its
        // own unless asked, as reading them needs sudo.
        let keys = Self.authorizedKeys()
        if created || installKeys, !keys.isEmpty, let home = getpwnam(user).map({ String(cString: $0.pointee.pw_dir) }) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sc-authorized-keys-\(getpid())")
            try (keys.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            try await sudo(["/usr/bin/install", "-d", "-o", user, "-g", "staff", "-m", "700", "\(home)/.ssh"])
            try await sudo(["/usr/bin/install", "-o", user, "-g", "staff", "-m", "600", file.path, "\(home)/.ssh/authorized_keys"])
        }
    }

    /// What macOS's Setup Assistant asks a new user, marked as seen: the
    /// screens of macOS 15 and 26, and the build and version it last ran for.
    static let setupAssistantSeen = [
        "DidSeeAccessibility", "DidSeeActivationLock", "DidSeeAppStore", "DidSeeAppearanceSetup", "DidSeeApplePaySetup",
        "DidSeeAvatarSetup", "DidSeeCloudDiagnostics", "DidSeeCloudSetup", "DidSeeIntelligence", "DidSeeLockdownMode",
        "DidSeePrivacy", "DidSeeScreenTime", "DidSeeSiriSetup", "DidSeeSyncSetup", "DidSeeSyncSetup2", "DidSeeTermsOfAddress",
        "DidSeeTouchIDSetup", "DidSeeTrueTonePrivacy", "DidSeeWallpaperSetup", "DidSeeiCloudLoginForStorageServices",
        "SkipFirstLoginOptimization",
    ]

    static func setupAssistantDoneScript(build: String, version: String) -> String {
        let domain = "com.apple.SetupAssistant"
        let seen = setupAssistantSeen.map { "/usr/bin/defaults write \(domain) \($0) -bool true" }
        // Everything a finished Setup Assistant leaves on macOS 26, the age
        // range, initial-setup and mini-buddy keys too. Whether they stop it
        // before a new user's first login isn't known yet; for a session
        // already stuck in it they didn't (it came back at the next login),
        // and clicking through it over Screen Sharing did.
        let versions = ["LastSeenBuddyBuildVersion": build, "LastSeenCloudProductVersion": version,
                        "LastSeenDiagnosticsProductVersion": version, "LastSeenSiriProductVersion": version,
                        "LastSeenIntelligenceProductVersion": version, "LastSeenAgeRangeSelectionProductVersion": version,
                        "InitialSetupBuildVersion": build, "InitialSetupProductVersion": version,
                        "LastPreLoginTasksPerformedBuild": build, "LastPreLoginTasksPerformedVersion": version,
                        "LastPrivacyBundleVersion": "2"]
            .sorted { $0.key < $1.key }
            .map { "/usr/bin/defaults write \(domain) \($0.key) -string \(Remote.quote($0.value))" }
        let miniBuddy = ["/usr/bin/defaults write \(domain) MiniBuddyLaunchReason -int 0",
                         "/usr/bin/defaults write \(domain) MiniBuddyShouldLaunchToResumeSetup -bool false"]
        return (seen + versions + miniBuddy).joined(separator: " && ")
    }

    static func osVersion(_ flag: String) async throws -> String {
        try await Proc.collect("/usr/bin/sw_vers", [flag]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the user's session is in Setup Assistant: its process list is
    /// any user's to read.
    static func inSetupAssistant(_ user: String) async throws -> Bool {
        try await Proc.collect("/usr/bin/pgrep", ["-u", user, "-x", "Setup Assistant"]).succeeded
    }

    /// The keys a test user lets in: those this user lets in (so whoever
    /// reaches this account from another Mac reaches the test users too) and
    /// this user's own (so sc reaches them from this Mac, as
    /// `<user>@localhost`), each once.
    static func authorizedKeys(ssh: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")) -> [String] {
        let files = [ssh.appendingPathComponent("authorized_keys")]
            + ((try? FileManager.default.contentsOfDirectory(at: ssh, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "pub" }.sorted { $0.path < $1.path }
        var seen: Set<String> = []
        return files.flatMap { file in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    /// Over SSH the login keychain is locked: ask for the password once, as
    /// `security` does, rather than fail after making the user.
    static func unlockKeychain(_ session: Session) async throws {
        let probe = try await Proc.collect("/usr/bin/security", ["show-keychain-info"])
        guard !probe.succeeded else { return }
        session.ui.detail("Your login keychain is locked (as over SSH). Unlock it to keep the test users' passwords:")
        let status = try await Proc.inheritingTerminal("/usr/bin/security", ["unlock-keychain"])
        guard status == 0 else { throw SCError("The keychain stayed locked, so nothing was changed.") }
    }

    private func sudo(_ arguments: [String]) async throws {
        // With nobody at a terminal to type the password, sudo would wait for ever.
        let cached = try await Proc.collect("/usr/bin/sudo", ["-n", "true"]).succeeded
        guard isatty(STDIN_FILENO) != 0 || cached else {
            throw SCError("This step needs an admin's password (sudo \(arguments.first ?? "")), and there's no terminal to type it in.",
                          hints: ["Run it from a terminal: sc session add, or sc --on <host> session add from one."])
        }
        let status = try await Proc.inheritingTerminal("/usr/bin/sudo", arguments)
        guard status == 0 else { throw SCError("`sudo \(arguments.first ?? "")` failed (exit \(status)).") }
    }

    /// Letters and digits, so it types the same on any keyboard layout: the
    /// keep-alive types it into the lock screen.
    static func newPassword() -> String {
        let characters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in characters.randomElement(using: &generator) ?? "x" })
    }
}
