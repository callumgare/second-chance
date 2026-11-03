//
//  BigFishSessionStore.swift
//  SecondChanceKit
//
//  The Big Fish sign-in Second Chance keeps between builds, as it keeps
//  Steam's: the person signs in once, and the next build's Game Manager
//  starts signed in. See docs/big-fish.md.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.BigFish")

/// The Game Manager's sign-in, kept in Application Support and never in a
/// wrapp. It is six registry values (`BigFishGameManager.accountValues`):
/// the Game Manager starts signed in from those alone, without its browser
/// profile, which is mostly cache. They're kept as a `.reg` fragment that
/// `reg import` puts back into the next build's prefix.
nonisolated public final class BigFishSessionStore: Sendable {
    /// `~/Library/Application Support/SecondChance/BigFish`.
    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SecondChance/BigFish")
    }

    /// Where a restored fragment is put in the prefix, for Wine's `reg import`.
    public static let fragmentWindowsPath = #"C:\windows\temp\second-chance-big-fish-sign-in.reg"#
    static let fragmentInPrefix = "drive_c/windows/temp/second-chance-big-fish-sign-in.reg"

    let root: URL
    var fragment: URL { root.appendingPathComponent("sign-in.reg") }

    public init(root: URL = BigFishSessionStore.defaultRoot) {
        self.root = root
    }

    /// Whether there is a sign-in to restore.
    public var hasSession: Bool { FileManager.default.fileExists(atPath: fragment.path) }

    /// Keep the sign-in in `prefix`'s registry, once its Wine session has
    /// ended and written it. False, keeping nothing, when it has none.
    public func capture(from prefix: URL) throws -> Bool {
        let userReg = try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)
        guard let fragment = Self.fragment(fromUserReg: userReg) else {
            logger.notice("The Game Manager has no sign-in to keep")
            return false
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(fragment.utf8).write(to: self.fragment, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fragment.path)
        logger.notice("Kept the Big Fish sign-in for the next build")
        return true
    }

    /// Copy the sign-in into `prefix` for `reg import`, returning its path
    /// as Wine names it, or nil when there is none.
    public func restore(into prefix: URL) throws -> String? {
        guard hasSession else { return nil }
        let destination = prefix.appendingPathComponent(Self.fragmentInPrefix)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fragment, to: destination)
        return Self.fragmentWindowsPath
    }

    /// Take the restored fragment out of `prefix` again, once imported.
    public static func removeFragment(from prefix: URL) {
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(fragmentInPrefix))
    }

    public func signOut() throws {
        if hasSession { try FileManager.default.removeItem(at: fragment) }
        logger.notice("Signed out of Big Fish Games: removed the kept sign-in")
    }

    // MARK: The registry

    /// The Game Manager's key as user.reg names it.
    static let userRegSection = #"[Software\\Big Fish Games\\Client]"#

    /// The sign-in's values in user.reg's text, as a `.reg` fragment that sets
    /// them, or nil without both its tokens. user.reg writes a value as a
    /// `.reg` file does.
    static func fragment(fromUserReg text: String) -> String? {
        var inSection = false
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") {
                inSection = line.hasPrefix(userRegSection + " ") || line == userRegSection
                continue
            }
            guard inSection, line.hasPrefix("\"") else { continue }
            let name = line.dropFirst().prefix { $0 != "\"" }
            if BigFishGameManager.accountValues.contains(String(name)) { lines.append(line) }
        }
        let names = Set(lines.map { String($0.dropFirst().prefix { $0 != "\"" }) })
        guard names.contains("AccessToken"), names.contains("RefreshToken") else { return nil }
        let key = #"HKEY_CURRENT_USER\Software\Big Fish Games\Client"#
        return "REGEDIT4\r\n\r\n[\(key)]\r\n" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
