import ArgumentParser
import Foundation
import WrappBuilder

/// Everything a test session needs beyond its login, done or put right:
/// its screen saver off (`ScreenSaverSetup`), the console user's signing
/// certificate in its keychain, Peekaboo with its grants, and SC Audio Tap
/// with its permission. `session add` runs it last, naming the users it
/// made or checked (`Remote.followUp`).
struct SessionSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set test sessions up: the screen saver off, your signing certificate, Peekaboo and SC Audio Tap with their grants (or only the --task ones).",
        discussion: """
        Run it on the Mac you're at. With --on it sets up that Mac's test \
        sessions; without, this Mac's. Each task skips what's done already. \
        screensaver: turns each test user's screen saver off, as nothing they \
        do counts as activity and its lock, after 20 minutes, stops a run. \
        signing: gives each test user your Apple Development certificate, so \
        its builds are signed as yours are (done on the test Mac, from your \
        keychain there; macOS may ask on its screen to allow the export). \
        peekaboo: installs Peekaboo if missing, starts it in each session, and \
        for a grant it lacks opens that pane there and Screen Sharing here, for \
        you to turn it on. audio: installs SC Audio Tap, which sc puppet audio \
        listens through, built and signed here, and for its system-audio \
        permission asks in that session, with Screen Sharing here, for you to \
        allow it.
        """
    )

    enum Task: String, CaseIterable, ExpressibleByArgument {
        case screensaver, signing, peekaboo, audio
    }

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Test users. Default: every one in that Mac's pool.")
    var users: [String] = []

    @Option(name: .customLong("task"), help: "A task to do, screensaver, signing, peekaboo or audio; give it again for more. Default: every one.")
    var only: [Task] = []

    func run() async throws {
        let session = try Session.start(global)
        let tasks = only.isEmpty ? Task.allCases : Task.allCases.filter(only.contains)
        let mac = Invocation.remote.map { Remote.parse($0, localRoot: session.repo.root).host }
        // Nothing can be set up in a session before its login, and a user
        // session add has just made waits for the keep-alive's.
        if !users.isEmpty {
            // A user that isn't a test user here never logs in: say so now,
            // not after waiting for one.
            let pool = SessionPool.users(fromPool: try await TestSessionAccess.asConsoleUser(mac, "cat \(SessionPool.file.path) 2>/dev/null").output)
            let unknown = Self.notInPool(users, pool: pool)
            if !unknown.isEmpty {
                let host = mac ?? ScreenLease.shortHostName()
                throw SCError("\(unknown.joined(separator: ", ")) \(unknown.count == 1 ? "isn't a test user" : "aren't test users") on \(host).",
                              hints: [pool.isEmpty ? "\(host) has none: sc session add" + (mac.map { " --on \($0)" } ?? "")
                                                   : "\(host)'s are \(pool.joined(separator: ", "))",
                                      "On another Mac: sc session setup \(users.joined(separator: " ")) --on <host>"])
            }
            try await Self.waitForLogins(users, on: mac, session: session)
        }
        // Only Peekaboo and the audio tap open Screen Sharing into a session
        // and put prompts on its screen; the screen saver's setting and the
        // certificate in the keychain show nothing there, so they go ahead
        // under someone else's lease.
        if tasks.contains(where: Self.disturbsSession) {
            try await Self.checkLeases(users, on: mac, session: session, ignoring: global.ignoreScreenLease)
        }
        var failed: [String] = []
        if tasks.contains(.screensaver) {
            do {
                try await ScreenSaverSetup.run(users: users.isEmpty ? nil : users, on: mac, session: session)
            } catch {
                failed.append("screensaver")
                session.ui.warning("The screen saver's set-up stopped: \(error)")
            }
        }
        if tasks.contains(.signing) {
            if let remote = Invocation.remote {
                // The certificate is in the console user's keychain on that Mac.
                // Leases were checked here, if at all: the sc there mustn't ask again.
                let status = try await Remote.run(on: remote, arguments: ["session", "setup", "--task", "signing", "--ignore-screen-lease"] + users)
                if status != 0 { failed.append("signing") }
            } else {
                // The test users' passwords are in the keychain too, locked over SSH.
                try await SessionAddCommand.unlockKeychain(session)
                await SessionAddCommand.installSigningIdentities(users.isEmpty ? SessionPool.users() : users, session: session)
            }
        }
        if tasks.contains(.peekaboo) {
            do {
                try await PeekabooSetup.run(users: users.isEmpty ? nil : users, on: mac, session: session)
            } catch {
                failed.append("peekaboo")
                session.ui.warning("Peekaboo's set-up stopped: \(error)")
            }
        }
        if tasks.contains(.audio) {
            do {
                try await AudioTapSetup.run(users: users.isEmpty ? nil : users, on: mac, session: session)
            } catch {
                failed.append("audio")
                session.ui.warning("SC Audio Tap's set-up stopped: \(error)")
            }
        }
        if !failed.isEmpty {
            throw SCError("Set-up didn't finish: \(failed.joined(separator: ", ")).",
                          hints: ["Run what's left again: sc session setup" + failed.map { " --task \($0)" }.joined()
                                  + users.map { " \($0)" }.joined() + (mac.map { " --on \($0)" } ?? "")])
        }
    }

    /// Whether a task opens Screen Sharing into a session or puts prompts on
    /// its screen, so a run there could be disturbed.
    static func disturbsSession(_ task: Task) -> Bool {
        task == .peekaboo || task == .audio
    }

    /// The users named that aren't in the Mac's pool, in the order named.
    static func notInPool(_ users: [String], pool: [String]) -> [String] {
        users.filter { !pool.contains($0) }
    }

    /// Set-up opens Screen Sharing into a session, restarts what runs there
    /// and puts macOS's prompts on its screen, so a session someone else has
    /// leased (a run going there) is left alone unless they say otherwise:
    /// a person is asked, defaulting to no, and a script, which can't be,
    /// stops unless it passed --ignore-screen-lease.
    static func checkLeases(_ users: [String], on mac: String?, session: Session, ignoring: Bool) async throws {
        let holder = ScreenLease.currentHolder(repoRoot: session.repo.root, branch: await ScreenLease.branch(of: session.repo.root))
        let leased = try await othersLeases(users, on: mac, holder: holder)
        guard !leased.isEmpty else { return }
        let host = mac ?? ScreenLease.shortHostName()
        let lines = leased.map { user, lease in
            "\(user)@\(host) is leased to \(lease.who)" + (lease.purpose.map { " for \"\($0)\"" } ?? "")
                + (lease.expires.map { " until \(ScreenLease.clock($0))" } ?? "")
        }
        for line in lines { session.ui.warning("\(line)") }
        if ignoring { return }
        let question = leased.count == 1 ? "Set it up anyway? That run may be disturbed." : "Set them up anyway? Those runs may be disturbed."
        switch try session.ui.confirm(question, default: false) {
        case true?:
            return
        case false?:
            throw SCError("Left \(leased.map(\.user).joined(separator: ", ")) alone.", exitCode: 1)
        case nil:
            throw SCError("Not setting up a test session someone else has leased.",
                          hints: ["Run it once that's done, or set it up anyway: sc session setup --ignore-screen-lease …"])
        }
    }

    /// Live leases on `users`' sessions (the pool's when none are named) on
    /// `mac`, held by anyone but `holder`. On another Mac the lease files are
    /// read over SSH, and a holder counts as running while its pid is.
    static func othersLeases(_ users: [String], on mac: String?, holder: ScreenLease.Holder) async throws -> [(user: String, lease: ScreenLease)] {
        if mac == nil {
            let statuses = await SessionPool.statuses(users: users.isEmpty ? SessionPool.users() : users)
            return statuses.compactMap { status in
                guard let lease = status.lease, !lease.holder.isSame(as: holder) else { return nil }
                return (status.user, lease)
            }
        }
        var users = users
        if users.isEmpty {
            users = SessionPool.users(fromPool: try await TestSessionAccess.asConsoleUser(mac, "cat \(SessionPool.file.path) 2>/dev/null").output)
        }
        guard !users.isEmpty else { return [] }
        let folder = SharedFolders.leases.path
        let script = "for u in \(users.map(Remote.quote).joined(separator: " ")); do f=\(folder)/$u.json; "
            + "[ -f \"$f\" ] && printf '%s\\t%s\\n' \"$u\" \"$(tr -d '\\n' < \"$f\")\"; done; true"
        let read = try await TestSessionAccess.asConsoleUser(mac, script)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [(user: String, lease: ScreenLease)] = []
        for line in read.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let lease = try? decoder.decode(ScreenLease.self, from: Data(parts[1].utf8)),
                  !lease.holder.isSame(as: holder) else { continue }
            if let expires = lease.expires, Date() >= expires { continue }
            found.append((String(parts[0]), lease))
        }
        let pids = found.map(\.lease.pid).filter { $0 != 0 }
        guard !pids.isEmpty else { return found.filter { $0.lease.expires != nil } }
        let running = try await TestSessionAccess.asConsoleUser(mac, "ps -o pid= -p \(pids.map(String.init).joined(separator: ",")) 2>/dev/null; true")
        let alive = Set(running.output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
        return found.filter { $0.lease.pid == 0 ? $0.lease.expires != nil : alive.contains($0.lease.pid) }
    }

    /// Who the last `session add` on `mac` (this Mac when nil) made or
    /// checked: none when it made nobody.
    static func addedLast(on mac: String?) async throws -> [String] {
        let path = SessionPool.justAddedFile.path
        let read = try await TestSessionAccess.asConsoleUser(mac, "if [ -f \(path) ]; then cat \(path); fi")
        guard read.succeeded else {
            throw SCError("Couldn't read which test users session add made on \(mac ?? ScreenLease.shortHostName()): "
                          + read.error.trimmingCharacters(in: .whitespacesAndNewlines),
                          hints: ["Set them up by name: sc session setup <user>…" + (mac.map { " --on \($0)" } ?? "")])
        }
        return SessionPool.users(fromPool: read.output)
    }

    /// A user `session add` just made isn't logged in until the keep-alive
    /// gets to it, and nothing can be set up in it before then. Waits for
    /// each to show among the Mac's console users.
    static func waitForLogins(_ users: [String], on mac: String?, session: Session) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        func loggedIn() async throws -> Set<String> {
            let listed = try await TestSessionAccess.asConsoleUser(mac, "/usr/sbin/ioreg -a -d1 -k IOConsoleUsers")
            return Set(SessionPool.logins(fromIORegPlist: Data(listed.output.utf8)).map(\.user))
        }
        var waiting = users
        let already = try await loggedIn()
        waiting.removeAll(where: already.contains)
        guard !waiting.isEmpty else { return }
        let names = waiting.joined(separator: ", ")
        // The keep-alive looks every minute; a first login, building the
        // user's home and keychain, takes a minute or two more.
        let limit: TimeInterval = 300
        try await session.ui.progressStep("Waiting for the keep-alive to log \(names) in on \(host)",
                                          success: "\(names) logged in on \(host).") { _ in
            let deadline = Date().addingTimeInterval(limit)
            while true {
                let now = try await loggedIn()
                waiting.removeAll(where: now.contains)
                if waiting.isEmpty { return }
                guard Date() < deadline else {
                    throw SCError("\(waiting.joined(separator: ", ")) still isn't logged in on \(host) after \(Int(limit / 60)) minutes.",
                                  hints: ["See where they stand: sc session" + (mac.map { " --on \($0)" } ?? ""),
                                          "Set them up once they're in: sc session setup \(waiting.joined(separator: " "))"
                                              + (mac.map { " --on \($0)" } ?? "")])
                }
                try await _Concurrency.Task.sleep(for: .seconds(3))
            }
        }
    }
}
