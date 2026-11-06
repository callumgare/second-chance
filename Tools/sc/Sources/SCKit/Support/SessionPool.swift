import Foundation
import WrappBuilder

/// The test users on a Mac whose logins run games in the background, each in
/// a GUI session of its own, so several runs (and the person at the Mac) don't
/// fight over one screen. See docs/dev-cli.md#test-sessions.
enum SessionPool {
    static let folder = SharedFolders.root
    /// One user name a line; `#` starts a comment.
    static let file = SharedFolders.pool
    /// Where the console user's keychain keeps each test user's password, as
    /// a generic password with the user's name as its account.
    static let keychainService = "second-chance-session"
    /// The users the last `session add` made or checked, one a line, for
    /// the `session setup --just-added` that follows it.
    static let justAddedFile = folder.appendingPathComponent("just-added")

    static func users(fromPool text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
    }

    /// Write the pool, which every user may change.
    static func write(_ users: [String]) throws {
        try ScreenLease.makeFolder(folder)
        try (users.joined(separator: "\n") + (users.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o666)
    }

    /// Record who `session add` made or checked.
    static func writeJustAdded(_ users: [String]) throws {
        try ScreenLease.makeFolder(folder)
        try (users.joined(separator: "\n") + "\n").write(to: justAddedFile, atomically: true, encoding: .utf8)
        chmod(justAddedFile.path, 0o666)
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

    // MARK: Naming them

    /// Test users are `second-chance-testing-1`, `-2`, …, so a pool reads the
    /// same on every Mac, scripts can count on the names, and nobody mistakes
    /// one for a person's account.
    static let namePrefix = "second-chance-testing-"

    /// The next `count` names in the scheme that no user on the Mac has.
    static func nextNames(_ count: Int, taken: Set<String>) -> [String] {
        var names: [String] = []
        var number = 1
        while names.count < count {
            let name = "\(namePrefix)\(number)"
            if !taken.contains(name) { names.append(name) }
            number += 1
        }
        return names
    }

    /// The first UID macOS gives a user who isn't an administrator's own.
    static let firstUID = 501

    /// The lowest UID from `firstUID` that no account has and no process
    /// runs as (a deleted account's can outlive it until a restart).
    static func freeUID(accounts: Set<Int>, running: Set<Int>) -> Int {
        var uid = firstUID
        while accounts.contains(uid) || running.contains(uid) { uid += 1 }
        return uid
    }

    /// The UIDs this Mac's accounts have, and those its processes run as.
    static func usedUIDs() async throws -> (accounts: Set<Int>, running: Set<Int>) {
        let listed = try await Proc.collect("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
        let processes = try await Proc.collect("/bin/ps", ["-axo", "uid="])
        guard listed.succeeded, processes.succeeded else {
            throw SCError("Couldn't list this Mac's users and processes to choose a UID: \(listed.error)\(processes.error)")
        }
        let accounts = listed.output.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
        let running = processes.output.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (Set(accounts), Set(running))
    }

    /// Every user name on this Mac.
    static func existingUsers() async -> Set<String> {
        guard let result = try? await Proc.collect("/usr/bin/dscl", [".", "-list", "/Users"]), result.succeeded else { return [] }
        return Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
    }

    // MARK: The Mac's installers

    /// Make the Mac's installers store (`InstallersStore`), which every
    /// user's checkout reads, if it isn't there, writable by every user.
    /// Returns what it did, for the person.
    static func makeInstallersStore(store: URL) async throws -> String {
        let fm = FileManager.default
        let said: String
        if fm.fileExists(atPath: store.path) {
            said = "Installers are kept in \(store.path), which every user on this Mac shares."
        } else {
            try await SharedFolders.make(store)
            said = "Made \(store.path), where every user on this Mac finds installers."
        }
        return said
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
    /// each is locked. The one reader of them: `GUISession.isScreenLocked`
    /// asks it too.
    static func logins() async -> [Login] {
        guard let result = quickly("/usr/sbin/ioreg", ["-a", "-d1", "-k", "IOConsoleUsers"]), result.status == 0 else { return [] }
        return logins(fromIORegPlist: result.output)
    }

    /// A small program's exit status and output, by Foundation's `Process`.
    /// The keep-alive asks these every few seconds from several tasks at once
    /// for hours, and through `Proc` (swift-subprocess) that left a lookup's
    /// continuation unresumed, its task waiting for ever with nothing logged.
    static func quickly(_ path: String, _ arguments: [String]) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    static func logins(fromIORegPlist data: Data) -> [Login] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let users = root["IOConsoleUsers"] as? [[String: Any]] else { return [] }
        return users.compactMap { entry in
            guard let uid = (entry["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value else { return nil }
            return Login(user: (entry["kCGSSessionUserNameKey"] as? String) ?? "", uid: uid,
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
        let result = quickly("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", user, "-w"])
        let password = String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .newlines)
        guard result?.status == 0, !password.isEmpty else {
            throw SCError("No password for \(user) in this user's keychain (security exit \(result?.status ?? -1)).",
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
