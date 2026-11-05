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

    /// Every user name on this Mac.
    static func existingUsers() async -> Set<String> {
        guard let result = try? await Proc.collect("/usr/bin/dscl", [".", "-list", "/Users"]), result.succeeded else { return [] }
        return Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
    }

    // MARK: The Mac's installers

    /// Installers, kept once per Mac for every user's checkout: each
    /// checkout's `installers` links here, so a test user's first run doesn't
    /// copy tens of gigabytes into its own home, and `--on` syncs write
    /// through the link.
    static let installers = folder.appendingPathComponent("installers")

    /// What every user may do in the shared installers, inherited by what's
    /// made inside: each user's sync replaces files another user's left.
    static let everyoneACL = "everyone allow list,add_file,search,delete,add_subdirectory,delete_child,readattr,writeattr,"
        + "readextattr,writeextattr,readsecurity,read,write,append,execute,file_inherit,directory_inherit"

    /// What sharing a checkout's installers will do, decided from what's
    /// there now.
    enum InstallersShare: Equatable {
        /// Already a link to the store.
        case linked
        /// The checkout has none: link to the store.
        case link
        /// The checkout's own folder becomes the store (the store is empty
        /// or missing), and the checkout links to it.
        case move
        /// Both hold installers: left alone, to be merged by hand.
        case both
    }

    static func installersShare(checkoutEntry: FileAttributeType?, linksToStore: Bool, storeHasFiles: Bool) -> InstallersShare {
        switch checkoutEntry {
        case .typeSymbolicLink? where linksToStore: return .linked
        case nil: return .link
        case .typeDirectory?: return storeHasFiles ? .both : .move
        default: return .both
        }
    }

    /// Make the store if it isn't there, and link `checkout`'s installers to
    /// it, moving the checkout's own folder in when the store is empty (one
    /// rename, on the same volume). Returns what it did, for the person.
    static func shareInstallers(checkout: URL) async throws -> String {
        let fm = FileManager.default
        let entry = checkout.appendingPathComponent("installers")
        let attributes = try? fm.attributesOfItem(atPath: entry.path)
        let type = attributes?[.type] as? FileAttributeType
        let target = (try? fm.destinationOfSymbolicLink(atPath: entry.path)).map { URL(fileURLWithPath: $0, relativeTo: checkout).standardizedFileURL.path }
        let storeFiles = ((try? fm.contentsOfDirectory(atPath: installers.path)) ?? []).filter { !$0.hasPrefix(".") }
        switch installersShare(checkoutEntry: type, linksToStore: target == installers.path, storeHasFiles: !storeFiles.isEmpty) {
        case .linked:
            return "\(entry.path) already links to \(installers.path)."
        case .both:
            return "\(entry.path) and \(installers.path) both hold installers, so neither was changed. Move what's missing into "
                + "\(installers.path), then replace the folder with a link: ln -s \(installers.path) \(entry.path)"
        case .link:
            try ScreenLease.makeFolder(folder)
            if !fm.fileExists(atPath: installers.path) { try fm.createDirectory(at: installers, withIntermediateDirectories: false) }
            try await allowEveryone(recursive: false)
            try fm.createSymbolicLink(at: entry, withDestinationURL: installers)
            return "\(entry.path) now links to \(installers.path), which every user on this Mac shares."
        case .move:
            try ScreenLease.makeFolder(folder)
            if fm.fileExists(atPath: installers.path) { try fm.removeItem(at: installers) }  // empty
            try fm.moveItem(at: entry, to: installers)
            try fm.createSymbolicLink(at: entry, withDestinationURL: installers)
            try await allowEveryone(recursive: true)
            return "Moved \(entry.path) to \(installers.path), which every user on this Mac shares, and linked it back."
        }
    }

    private static func allowEveryone(recursive: Bool) async throws {
        let result = try await Proc.collect("/bin/chmod", (recursive ? ["-R"] : []) + ["+a", everyoneACL, installers.path])
        guard result.succeeded else {
            throw SCError("Couldn't let every user write to \(installers.path): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
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
