import ArgumentParser
import Foundation

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
                      SessionKeepAliveCommand.self, SessionAddCommand.self],
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
            let renewable = statuses.first { $0.lease.map { $0.isTakenByHand && $0.holder.isSame(as: holder) } ?? false }
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
        session.ui.detail("Run in it: sc --on \(chosen.user)@\(host):\(checkout) <command>")
        session.ui.detail("Give it back: sc --on \(host) session release \(chosen.user)")
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
            "ProcessType": "Background",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
        let result = try await Proc.collect("/bin/launchctl", ["bootstrap", domain, plist.path])
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
                while !Task.isCancelled {
                    try connection.refresh()
                    if Date().timeIntervalSince(checked) >= 10 {
                        checked = Date()
                        if await SessionPool.logins().first(where: { $0.user == user })?.locked == true {
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
        abstract: "Set this Mac up for test sessions: make test users, share installers, start the keep-alive.",
        discussion: """
        Run it as the admin who uses the Mac's display, at the Mac or with \
        sc --on <host> session add from a terminal: it uses sudo, and keeps \
        each new user's password in this user's keychain (asking to unlock it \
        over SSH). It makes standard users named second-chance-testing-1, -2, … (or the \
        names given; an existing user whose password is in the keychain is \
        adopted), lets them in over SSH and Screen Sharing with this user's \
        authorized keys, and adds them to the pool. Then it moves this \
        checkout's installers into the store every user shares, and installs \
        the keep-alive, which logs the new sessions in. Running it again \
        fixes whatever is missing. See docs/dev-cli.md#test-sessions.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Test users' short names. Default: the next free second-chance-testing-<n>.")
    var users: [String] = []

    @Option(help: "How many to make when no names are given.")
    var count: Int = 1

    @Flag(help: "Give existing test users this user's authorized SSH keys too (new ones always get them).")
    var installKeys = false

    @Flag(help: "Leave this checkout's installers where they are.")
    var keepInstallers = false

    func validate() throws {
        for user in users where user.range(of: #"^[a-z][a-z0-9_-]{1,30}$"#, options: .regularExpression) == nil {
            throw ValidationError("\(user): a user's short name is lower-case letters, digits and hyphens, starting with a letter.")
        }
        if !(1...9).contains(count) { throw ValidationError("--count is 1 to 9.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        var pool = SessionPool.users()
        let names = users.isEmpty
            ? SessionPool.nextNames(count, taken: await SessionPool.existingUsers())
            : users
        try await Self.unlockKeychain(session)
        for user in names {
            try await add(user, session: session)
            if !pool.contains(user) { pool.append(user) }
        }
        try ScreenLease.makeFolder(SessionPool.folder)
        try (pool.joined(separator: "\n") + "\n").write(to: SessionPool.file, atomically: true, encoding: .utf8)
        chmod(SessionPool.file.path, 0o666)
        session.ui.detail("The pool: \(pool.joined(separator: ", ")).")

        if !keepInstallers {
            session.ui.detail(try await SessionPool.shareInstallers(checkout: session.repo.root))
        }
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
        let keys = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/authorized_keys")
        if created || installKeys, FileManager.default.fileExists(atPath: keys.path),
           let home = getpwnam(user).map({ String(cString: $0.pointee.pw_dir) }) {
            try await sudo(["/usr/bin/install", "-d", "-o", user, "-g", "staff", "-m", "700", "\(home)/.ssh"])
            try await sudo(["/usr/bin/install", "-o", user, "-g", "staff", "-m", "600", keys.path, "\(home)/.ssh/authorized_keys"])
        }
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
