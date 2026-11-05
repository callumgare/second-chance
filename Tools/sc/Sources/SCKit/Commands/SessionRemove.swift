import ArgumentParser
import Foundation

/// `session add`'s counterpart: a test user out of the Mac's pool, and, if
/// asked, gone from the Mac altogether.
struct SessionRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Take test users out of this Mac's pool, and, if you say so, delete their accounts.",
        discussion: """
        Takes each user out of the pool and clears its lease, and restarts the \
        keep-alive so it lets the session go. Then asks whether to delete the \
        account too, with all its files (default: no); without a terminal to \
        ask on, it doesn't, unless --delete-account. Deleting logs the user out \
        and deletes the account and its home (sysadminctl -deleteUser, which \
        takes sudo), and removes its password from this user's keychain. Kept, \
        the account and its password stay, so sc session add can take it back. \
        A session leased to a run is left alone unless --force.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The test users to remove.")
    var users: [String]

    @Flag(help: "Delete the accounts and their files without asking.")
    var deleteAccount = false

    @Flag(help: "Remove a session leased to a run too, ending the run.")
    var force = false

    func validate() throws {
        guard !users.isEmpty else { throw ValidationError("Name the test users to remove: sc session remove <user>…") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let pool = SessionPool.users()
        let unknown = users.filter { !pool.contains($0) && getpwnam($0) == nil }
        guard unknown.isEmpty else {
            throw SCError("No test user called \(unknown.joined(separator: ", ")) on \(ScreenLease.shortHostName()).",
                          hints: ["See them: sc session list"])
        }
        let statuses = await SessionPool.statuses(users: users)
        if !force, let leased = statuses.first(where: { $0.lease != nil }) {
            throw SCError("\(SessionPool.screenName(of: leased.user)) is leased to a run: \(leased.summary).",
                          hints: ["Remove it anyway, ending the run: sc session remove --force \(leased.user)"])
        }

        try SessionPool.write(pool.filter { !users.contains($0) })
        for user in users { try? FileManager.default.removeItem(at: ScreenLease.file(for: user)) }
        if await SessionKeepAliveCommand.isInstalled() {
            _ = try await Proc.collect("/bin/launchctl", ["kickstart", "-k", "\(SessionKeepAliveCommand.domain)/\(SessionKeepAliveCommand.label)"])
        }
        session.ui.detail("Took \(users.joined(separator: ", ")) out of the pool. The pool: \(SessionPool.users().joined(separator: ", ").ifEmpty("none")).")

        let delete: Bool
        if deleteAccount {
            delete = true
        } else {
            let question = users.count == 1 ? "Also delete the user account \(users[0]) and all its files?"
                                            : "Also delete the user accounts \(users.joined(separator: ", ")) and all their files?"
            delete = try session.ui.confirm(question, default: false) ?? false
        }
        guard delete else {
            session.ui.success("Removed from the pool; the accounts are kept.",
                               takeaways: ["Put one back: sc session add \(users[0])", "Delete it later: sc session remove --delete-account \(users[0])"])
            return
        }
        for status in statuses {
            if let login = status.login {
                session.ui.detail("Logging out \(status.user). sudo may ask for your password.")
                try await SessionAddCommand.sudo(["/bin/launchctl", "bootout", "gui/\(login.uid)"])
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline, await SessionPool.logins().contains(where: { $0.user == status.user }) {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            try await session.ui.progressStep("Deleting the account \(status.user) and its files", success: "Deleted \(status.user)") { _ in
                try await SessionAddCommand.sudo(["/usr/sbin/sysadminctl", "-deleteUser", status.user])
            }
            _ = try await Proc.collect("/usr/bin/security", ["delete-generic-password", "-s", SessionPool.keychainService, "-a", status.user])
        }
        session.ui.success("Deleted \(users.joined(separator: ", ")), with their files and saved passwords.")
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
