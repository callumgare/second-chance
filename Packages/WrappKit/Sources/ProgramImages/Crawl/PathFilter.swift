//
//  PathFilter.swift
//  ProgramImages
//
//  Paths the crawl leaves alone, or reads but ranks down, kept as data
//  (Resources/filters.json) rather than code, so the list can grow without
//  touching the crawler: text, sound and fonts; installers' own parts; a
//  wrapp's engines and Wine's own Windows; runtime libraries.

import Darwin
import Foundation

nonisolated public struct PathFilter: Sendable {
    public struct Rule: Codable, Sendable {
        public let pattern: String
        public let reason: String
    }

    private struct Table: Codable {
        let keep: [String]
        let skip: [Rule]
        let demote: [Rule]
        /// Only for a wrapp: everything of the wrapp's own (its engines'
        /// data, ScummVM's icons of every other game) is outside
        /// Contents/SharedSupport.
        let wrapp: [Rule]?
    }

    public enum Verdict: Equatable, Sendable {
        case read
        case skip(String)
        case demote(String)
    }

    private let keep: [String]
    private let skip: [Rule]
    private let demote: [Rule]
    private let wrapp: [Rule]

    /// The table shipped with the package, or the one at `url`.
    public init(contentsOf url: URL? = nil) throws {
        guard let url = url ?? Self.shippedTable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The filter table isn't with the program"])
        }
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        keep = table.keep.map { $0.lowercased() }
        skip = table.skip
        demote = table.demote
        wrapp = table.wrapp ?? []
    }

    public init(keep: [String] = [], skip: [Rule] = [], demote: [Rule] = [], wrapp: [Rule] = []) {
        self.keep = keep
        self.skip = skip
        self.demote = demote
        self.wrapp = wrapp
    }

    /// The filter for a wrapp: its `wrapp` rules too, keeping `paths` (its
    /// icon) unless the other rules skip them (Second Chance's own icons).
    public func forWrapp(keeping paths: [String]) -> PathFilter {
        let kept = paths.filter { if case .skip = verdict(for: $0) { false } else { true } }
        return PathFilter(keep: keep + kept.map { $0.lowercased() }, skip: skip + wrapp, demote: demote)
    }

    /// The shipped table, in the package's resource bundle: found where
    /// SwiftPM's `Bundle.module` looks (beside the program, or in the app's
    /// resources), without its accessor, which is the main actor's.
    static var shippedTable: URL? {
        let bundleName = "WrappKit_ProgramImages.bundle"
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for place in places.compactMap({ $0 }) {
            for candidate in [place.appendingPathComponent(bundleName + "/filters.json"),
                              place.appendingPathComponent(bundleName + "/Contents/Resources/filters.json")]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Beside the binary this code is in, or a few folders up from it
        // (`swift test`: the bundle sits beside the .xctest bundle).
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { return nil }
        var folder = URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = folder.appendingPathComponent(bundleName + "/filters.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// The verdict for `path`, a file's path inside its container.
    public func verdict(for path: String) -> Verdict {
        let path = path.lowercased()
        let name = path.split(separator: "/").last.map(String.init) ?? path
        func matches(_ pattern: String) -> Bool {
            let pattern = pattern.lowercased()
            return pattern.contains("/") ? Self.glob(pattern, path) || Self.glob("**/" + pattern, path)
                : Self.glob(pattern, name)
        }
        if keep.contains(where: matches) { return .read }
        if let rule = skip.first(where: { matches($0.pattern) }) { return .skip(rule.reason) }
        if let rule = demote.first(where: { matches($0.pattern) }) { return .demote(rule.reason) }
        return .read
    }

    /// Glob matching: `**/` any number of folders, `/**` everything below,
    /// `*` anything but a slash, `?` one character.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern)
        let text = Array(text)
        var memo: [Int: Bool] = [:]
        func match(_ p: Int, _ t: Int) -> Bool {
            let key = p * (text.count + 1) + t
            if let known = memo[key] { return known }
            let result: Bool
            if p == pattern.count {
                result = t == text.count
            } else if pattern[p] == "*", p + 1 < pattern.count, pattern[p + 1] == "*" {
                // "**/" may match nothing; "**" matches anything, slashes too.
                let next = p + 2 < pattern.count && pattern[p + 2] == "/" ? p + 3 : p + 2
                result = match(next, t) || (t < text.count && match(p, t + 1))
            } else if pattern[p] == "*" {
                result = match(p + 1, t) || (t < text.count && text[t] != "/" && match(p, t + 1))
            } else if t < text.count, pattern[p] == "?" || pattern[p] == text[t] {
                result = match(p + 1, t + 1)
            } else {
                result = false
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }
}
