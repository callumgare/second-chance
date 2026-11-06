import Foundation

/// `sc session setup`'s screensaver task: each test user's screen saver
/// turned off. The keep-alive is a viewer that sends no input, and a game's
/// posted events aren't the person's, so macOS counts a test session as idle
/// whatever runs there. Left at its default, the screen saver starts after
/// 20 minutes and locks the session; the keep-alive unlocks it within
/// seconds, but a launch or a puppet action that lands meanwhile fails with
/// "the screen is locked". See docs/dev-cli.md#test-sessions.
enum ScreenSaverSetup {
    /// What turns it off, as the user over SSH: the per-host setting System
    /// Settings writes for "Start Screen Saver when inactive: Never", which
    /// the user's cfprefsd hands to their session as it runs.
    static let disableCommand = "defaults -currentHost write com.apple.screensaver idleTime -int 0"

    /// Prints the idle time in seconds, or nothing when it's never been set
    /// (macOS's default, 20 minutes).
    static let readCommand = "defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null; true"

    /// Whether `idleTime`'s value, as `readCommand` prints it, means the
    /// screen saver never starts.
    static func isOff(_ output: String) -> Bool {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) == 0
    }

    /// Turn it off for `users` (every test user in the pool when nil) on
    /// `mac` (this Mac when nil), skipping those already done.
    static func run(users given: [String]?, on mac: String?, session: Session) async throws {
        let host = mac ?? ScreenLease.shortHostName()
        let users: [String]
        if let given, !given.isEmpty {
            users = given
        } else {
            let pool = try await TestSessionAccess.asConsoleUser(mac, "cat \(SessionPool.file.path) 2>/dev/null").output
            users = SessionPool.users(fromPool: pool)
        }
        guard !users.isEmpty else { throw SCError("\(host) has no test sessions.", hints: ["Add some there: sc session add"]) }
        var failed: [String] = []
        for user in users {
            let destination = "\(user)@\(mac ?? "localhost")"
            let before = try await TestSessionAccess.ssh(destination, readCommand)
            if before.succeeded, isOff(before.output) {
                session.ui.detail("\(user)@\(host): the screen saver is already off.")
                continue
            }
            let set = try await TestSessionAccess.ssh(destination, "\(disableCommand) && \(readCommand)")
            if set.succeeded, isOff(set.output) {
                session.ui.detail("\(user)@\(host): turned the screen saver off.")
            } else {
                failed.append(user)
                let reason = set.error.trimmingCharacters(in: .whitespacesAndNewlines)
                session.ui.warning("\(user)@\(host): couldn't turn the screen saver off\(reason.isEmpty ? "" : ": \(reason)").")
            }
        }
        guard failed.isEmpty else {
            throw SCError("The screen saver is still on in \(failed.joined(separator: ", ")) on \(host).")
        }
        session.ui.success("The screen saver is off in \(users.count == 1 ? users[0] : "\(users.count) test sessions") on \(host).")
    }
}
