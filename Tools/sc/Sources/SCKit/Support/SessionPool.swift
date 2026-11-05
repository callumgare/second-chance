import Foundation

/// The test users on a Mac whose logins run games in the background, each in
/// a GUI session of its own, so several runs (and the person at the Mac) don't
/// fight over one screen. See docs/dev-cli.md#test-sessions.
enum SessionPool {
    static let folder = URL(fileURLWithPath: "/Users/Shared/second-chance")
    /// One user name a line; `#` starts a comment.
    static let file = folder.appendingPathComponent("pool")
    /// Where the console user's keychain keeps each test user's password, as
    /// a generic password with the user's name as its account.
    static let keychainService = "second-chance-session"

    static func users(fromPool text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
    }

    static func users() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return users(fromPool: text)
    }

    /// How a screen is named in messages: the Mac's for its own user, and
    /// `<mac>/<user>` for a test session's.
    static func screenName(of user: String = NSUserName(), host: String = ScreenLease.shortHostName(),
                           pool: [String] = users()) -> String {
        pool.contains(user) ? "\(host)/\(user)" : host
    }

    // MARK: Sessions logged in now

    /// A GUI login, from the console users WindowServer lists.
    struct Login: Equatable {
        var user: String
        var uid: uid_t
        /// Its screen is the one on the display (or a viewer's).
        var onConsole: Bool
        var locked: Bool
    }

    /// Every GUI login on this Mac, from `ioreg -a`'s console users: unlike
    /// launchd's per-user domains, it's readable by any user, and says whether
    /// each is locked.
    static func logins() async -> [Login] {
        guard let result = try? await Proc.collect("/usr/sbin/ioreg", ["-a", "-d1", "-k", "IOConsoleUsers"]),
              result.succeeded else { return [] }
        return logins(fromIORegPlist: Data(result.output.utf8))
    }

    static func logins(fromIORegPlist data: Data) -> [Login] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let users = root["IOConsoleUsers"] as? [[String: Any]] else { return [] }
        return users.compactMap { entry in
            guard let name = entry["kCGSSessionUserNameKey"] as? String,
                  let uid = (entry["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value else { return nil }
            return Login(user: name, uid: uid,
                         onConsole: (entry["kCGSSessionOnConsoleKey"] as? Bool) ?? false,
                         locked: (entry["CGSSessionScreenIsLocked"] as? Bool) ?? false)
        }
    }

    // MARK: Where each stands

    struct Status {
        var user: String
        var login: Login?
        var lease: ScreenLease?

        var isFree: Bool { login != nil && login?.locked == false && lease == nil }

        var summary: String {
            guard let login else { return "not logged in" }
            var words = [login.locked ? "logged in, locked" : "logged in"]
            if let lease {
                words.append("leased to \(lease.who)" + (lease.purpose.map { " for \"\($0)\"" } ?? "")
                             + (lease.expires.map { " until \(ScreenLease.clock($0))" } ?? ""))
            } else {
                words.append("free")
            }
            return words.joined(separator: ", ")
        }
    }

    /// A test user's password, from the console user's keychain. Over SSH
    /// that keychain is locked, so this works only in the GUI session.
    static func password(for user: String) async throws -> String {
        let result = try await Proc.collect("/usr/bin/security",
                                                 ["find-generic-password", "-s", keychainService, "-a", user, "-w"])
        let password = result.output.trimmingCharacters(in: .newlines)
        guard result.succeeded, !password.isEmpty else {
            throw SCError("No password for \(user) in this user's keychain (security exit \(result.status)).",
                          hints: ["Store it, in the GUI session: security add-generic-password -s \(keychainService) -a \(user) -w",
                                  "Over SSH the keychain is locked: run this in the GUI session (a LaunchAgent, or sc in-gui-session)."])
        }
        return password
    }

    static func statuses(users: [String] = users()) async -> [Status] {
        let logins = await logins()
        return users.map { user in
            let file = ScreenLease.file(for: user)
            var lease = ScreenLease.read(file)
            if let stale = lease, !stale.isAlive {
                try? FileManager.default.removeItem(at: file)
                lease = nil
            }
            return Status(user: user, login: logins.first { $0.user == user }, lease: lease)
        }
    }
}
