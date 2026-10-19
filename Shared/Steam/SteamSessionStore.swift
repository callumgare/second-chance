//
//  SteamSessionStore.swift
//  Shared
//
//  One Steam sign-in shared by every wrapp. Each wrapp keeps its own Steam
//  install, but the files that carry the login live here, outside any wrapp:
//  copied into a wrapp's prefix before its Steam starts, and back out after
//  it quits. See docs/steam.md.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.SteamSession")

nonisolated final class SteamSessionStore: @unchecked Sendable {
    /// The files, relative to a prefix, that carry a remembered Steam login.
    /// Found by experiment: with these and `AutoLoginUser`, a Steam that has
    /// never signed in signs in by itself; without `loginusers.vdf` it asks
    /// for credentials, and without `config.vdf` the server rejects the token.
    static let files = [
        "drive_c/Program Files (x86)/Steam/config/loginusers.vdf",
        "drive_c/Program Files (x86)/Steam/config/config.vdf",
        "drive_c/users/\(WineEnvironment.wineUsername)/AppData/Local/Steam/local.vdf",
    ]
    /// The one that holds the token. Its modification time says which of two
    /// sessions is newer.
    static let tokenFile = files[2]
    /// The registry key holding `AutoLoginUser`, as user.reg names it.
    static let registrySection = #"[Software\\Valve\\Steam]"#
    static let registryValue = "AutoLoginUser"

    /// `~/Library/Application Support/SecondChance/Steam`.
    static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SecondChance/Steam")
    }

    let root: URL
    var sessionDir: URL { root.appendingPathComponent("session") }
    /// The `.reg` fragment that sets `AutoLoginUser`, imported with `reg import`.
    var registryFragment: URL { sessionDir.appendingPathComponent("login.reg") }
    /// Outside `sessionDir`, so signing out can delete that whole directory.
    private var lockFile: URL { root.appendingPathComponent("session.lock") }

    init(root: URL = SteamSessionStore.defaultRoot) {
        self.root = root
    }

    /// Whether there is a session to restore.
    var hasSession: Bool {
        (Self.files.map { sessionDir.appendingPathComponent($0) } + [registryFragment])
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Restore

    /// Copy the session into `prefix`, keeping the files' modification times.
    /// Returns where it put the `.reg` fragment (inside the prefix, so Wine can
    /// read it as `C:\…`) for the caller to `reg import`, or nil when there is
    /// no session — Steam will then ask the user to sign in.
    @discardableResult
    func restore(into prefix: URL) throws -> URL? {
        try withLock {
            guard hasSession else {
                logger.notice("No saved Steam session to restore")
                return nil
            }
            for file in Self.files {
                try copyKeepingDate(from: sessionDir.appendingPathComponent(file), to: prefix.appendingPathComponent(file))
            }
            let fragment = prefix.appendingPathComponent(Self.fragmentPathInPrefix)
            try copyKeepingDate(from: registryFragment, to: fragment)
            logger.notice("Restored the saved Steam session into \(prefix.path)")
            return fragment
        }
    }

    /// Where `restore` leaves the `.reg` fragment, relative to the prefix.
    static let fragmentPathInPrefix = "drive_c/windows/temp/second-chance-steam-login.reg"
    /// The same, as Wine sees it.
    static let fragmentWindowsPath = #"C:\windows\temp\second-chance-steam-login.reg"#

    // MARK: Capture

    enum CaptureResult: Equatable, Sendable {
        case saved
        /// The prefix holds the same session as the store.
        case unchanged
        /// Not saved: Steam didn't sign in. A rejected token makes Steam
        /// rewrite `local.vdf` without it, and saving that would sign out
        /// every wrapp.
        case notSignedIn
        /// Not saved: the store holds a newer session, saved by another wrapp
        /// since this one restored.
        case storeIsNewer
        /// Not saved: a file or the registry value is missing from the prefix.
        case incomplete(String)
    }

    /// Save the session in `prefix` to the store. Call it once Wine has
    /// stopped — user.reg is only written out then — and only when Steam
    /// signed in during the run.
    @discardableResult
    func capture(from prefix: URL, signedIn: Bool) throws -> CaptureResult {
        guard signedIn else {
            logger.notice("Not saving the Steam session: Steam didn't sign in this time")
            return .notSignedIn
        }
        return try withLock {
            for file in Self.files where !FileManager.default.fileExists(atPath: prefix.appendingPathComponent(file).path) {
                logger.warning("Not saving the Steam session: \(file) is missing from the prefix")
                return .incomplete(file)
            }
            guard let line = try Self.registryLine(inUserReg: prefix.appendingPathComponent("user.reg")) else {
                logger.warning("Not saving the Steam session: \(Self.registryValue) isn't in the prefix's user.reg")
                return .incomplete(Self.registryValue)
            }
            let fragment = Self.fragment(registryLine: line)

            if hasSession {
                let ours = try modificationDate(prefix.appendingPathComponent(Self.tokenFile))
                let theirs = try modificationDate(sessionDir.appendingPathComponent(Self.tokenFile))
                if theirs > ours {
                    logger.notice("Not saving the Steam session: the saved one is newer (another wrapp saved it since)")
                    return .storeIsNewer
                }
                let same = try Self.files.allSatisfy {
                    try Data(contentsOf: prefix.appendingPathComponent($0)) == Data(contentsOf: sessionDir.appendingPathComponent($0))
                } && (try? Data(contentsOf: registryFragment)) == Data(fragment.utf8)
                if same {
                    logger.debug("The Steam session is unchanged")
                    return .unchanged
                }
            }

            // Build the new session beside the old and swap it in, so a
            // failure part-way leaves the old one whole.
            let staging = root.appendingPathComponent("session.new")
            try? FileManager.default.removeItem(at: staging)
            try createPrivateDirectory(staging)
            for file in Self.files {
                try copyKeepingDate(from: prefix.appendingPathComponent(file), to: staging.appendingPathComponent(file))
            }
            try writePrivate(Data(fragment.utf8), to: staging.appendingPathComponent(registryFragment.lastPathComponent))
            if FileManager.default.fileExists(atPath: sessionDir.path) {
                _ = try FileManager.default.replaceItemAt(sessionDir, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: sessionDir)
            }
            logger.notice("Saved the Steam session")
            return .saved
        }
    }

    /// The `"AutoLoginUser"=…` line from a Wine user.reg, verbatim.
    static func registryLine(inUserReg url: URL) throws -> String? {
        let text = try String(contentsOf: url, encoding: .utf8)
        var inSection = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inSection = line.hasPrefix(registrySection + " ") || line == registrySection
                continue
            }
            if inSection, line.hasPrefix("\"\(registryValue)\"=") {
                return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// A `.reg` file setting that one value. user.reg and `.reg` files quote
    /// and escape values the same way, so the line carries across unchanged.
    static func fragment(registryLine: String) -> String {
        "Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\Software\\Valve\\Steam]\r\n\(registryLine)\r\n"
    }

    // MARK: Sign out

    func signOut() throws {
        try withLock {
            if FileManager.default.fileExists(atPath: sessionDir.path) {
                try FileManager.default.removeItem(at: sessionDir)
            }
            logger.notice("Signed out of Steam: removed the saved session")
        }
    }

    // MARK: Files

    /// Run `body` holding an exclusive lock, so two wrapps never restore or
    /// save at the same moment.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try createPrivateDirectory(root)
        let fd = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockFile.path]) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: lockFile.path]) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func copyKeepingDate(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let date = try modificationDate(source)
        try writePrivate(try Data(contentsOf: source), to: destination)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.modificationDate] as? Date ?? .distantPast
    }
}
