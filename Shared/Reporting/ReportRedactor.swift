//
//  ReportRedactor.swift
//  Shared
//
//  Takes the person out of what a failure report sends. Logs name the home
//  folder on almost every line (`/Users/<name>/…`), and Steam's files carry
//  the account it signed in with; none of that helps diagnose a failure.
//  Everything a report sends — event text, log files, diagnostics bundles —
//  goes through `redact` first.

import Foundation
import SystemConfiguration

nonisolated struct ReportRedactor: Sendable {

    /// What identifies this Mac and its user.
    struct Identity: Sendable {
        var homePath: String
        var userName: String
        var fullName: String
        var computerNames: [String]
        /// Steam account and persona names, from the saved sign-in.
        var steamNames: [String]
    }

    let identity: Identity
    private let replacements: [(String, String)]

    init(identity: Identity) {
        self.identity = identity
        var pairs: [(String, String)] = []
        let home = identity.homePath.hasSuffix("/") ? String(identity.homePath.dropLast()) : identity.homePath
        if !home.isEmpty {
            pairs.append(("file://" + (home.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? home), "file://~"))
            if let encoded = home.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), encoded != home {
                pairs.append((encoded, "~"))
            }
            pairs.append((home, "~"))
        }
        pairs += identity.computerNames.filter { $0.count >= 3 }.map { ($0, "<computer>") }
        // Longest first, so a name that contains another goes whole.
        self.replacements = pairs.sorted { $0.0.count > $1.0.count }
    }

    /// This Mac's identity, with the Steam names from the saved sign-in.
    static let current = ReportRedactor(identity: Identity(
        homePath: FileManager.default.homeDirectoryForCurrentUser.path,
        userName: NSUserName(),
        fullName: NSFullUserName(),
        computerNames: currentComputerNames(),
        steamNames: currentSteamNames()
    ))

    func redact(_ text: String) -> String {
        var result = text
        for (needle, replacement) in replacements where result.contains(needle) {
            result = result.replacingOccurrences(of: needle, with: replacement)
        }
        // Another account's home, or one named differently (a sudo, a
        // second user): keep that it was a home folder, drop whose.
        result = result.replacingOccurrences(
            of: #"/Users/(?!Shared/)[^/\s"':]+"#, with: "/Users/<user>", options: .regularExpression
        )
        // Names stand alone as words. A name too short to be distinctive
        // ("al") would take letters out of ordinary words, so it stays.
        for name in [identity.fullName, identity.userName] + identity.steamNames where name.count >= 3 {
            result = result.replacingOccurrences(
                of: #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}_])"#,
                with: "<user>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // A SteamID64 names an account as surely as its name does.
        result = result.replacingOccurrences(of: #"\b7656119\d{10}\b"#, with: "<steam-id>", options: .regularExpression)
        return result
    }

    /// Redact every string in a JSON-like value: dictionaries, arrays, strings.
    func redact(value: Any) -> Any {
        switch value {
        case let string as String:
            return redact(string)
        case let dictionary as [String: Any]:
            return dictionary.mapValues { redact(value: $0) }
        case let array as [Any]:
            return array.map { redact(value: $0) }
        default:
            return value
        }
    }

    /// Copy `source` to `destination`, redacted. Text files are rewritten;
    /// anything that isn't UTF-8 is left out, since it can't be checked.
    func redactFile(at source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try Data(redact(text).utf8).write(to: destination, options: .atomic)
    }

    // MARK: This Mac

    private static func currentComputerNames() -> [String] {
        var names: [String] = []
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            names.append(name)
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            names += [local, local + ".local"]
        }
        return names
    }

    /// The account and persona names in the saved Steam sign-in, if any.
    private static func currentSteamNames() -> [String] {
        let session = SteamSessionStore().sessionDir
        var names: Set<String> = []
        let loginUsers = session.appendingPathComponent(SteamSessionStore.files[0])
        if let text = try? String(contentsOf: loginUsers, encoding: .utf8) {
            names.formUnion(values(of: ["AccountName", "PersonaName"], in: text))
        }
        if let fragment = try? String(contentsOf: SteamSessionStore().registryFragment, encoding: .utf8) {
            names.formUnion(values(of: ["AutoLoginUser"], in: fragment))
        }
        return names.sorted()
    }

    /// `"Key" "value"` (VDF) and `"Key"="value"` (.reg) pairs.
    static func values(of keys: [String], in text: String) -> [String] {
        keys.flatMap { key -> [String] in
            let pattern = #""\#(key)"\s*=?\s*"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
    }
}
