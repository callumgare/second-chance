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
    // Compiled once: a crawl asks for every file's verdict, tens of thousands of times.
    private let keepMatchers: [Matcher]
    private let skipMatchers: [(rule: Rule, matcher: Matcher)]
    private let demoteMatchers: [(rule: Rule, matcher: Matcher)]

    /// The table shipped with the package, or the one at `url`.
    public init(contentsOf url: URL? = nil) throws {
        guard let url = url ?? Self.shippedTable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The filter table isn't with the program"])
        }
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        self.init(keep: table.keep, skip: table.skip, demote: table.demote, wrapp: table.wrapp ?? [])
    }

    public init(keep: [String] = [], skip: [Rule] = [], demote: [Rule] = [], wrapp: [Rule] = []) {
        self.keep = keep.map { $0.lowercased() }
        self.skip = skip
        self.demote = demote
        self.wrapp = wrapp
        keepMatchers = self.keep.map(Matcher.init)
        skipMatchers = skip.map { ($0, Matcher($0.pattern)) }
        demoteMatchers = demote.map { ($0, Matcher($0.pattern)) }
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
        let path = Array(path.lowercased().utf8)
        let name = path.split(separator: UInt8(ascii: "/")).last.map(Array.init) ?? path
        if keepMatchers.contains(where: { $0.matches(path: path, name: name) }) { return .read }
        if let rule = skipMatchers.first(where: { $0.matcher.matches(path: path, name: name) }) { return .skip(rule.rule.reason) }
        if let rule = demoteMatchers.first(where: { $0.matcher.matches(path: path, name: name) }) { return .demote(rule.rule.reason) }
        return .read
    }

    /// A rule's pattern, compiled: one with a slash is matched against the
    /// whole path at any depth (as if it began `**/`), one without against
    /// the file's name.
    struct Matcher: Sendable {
        let glob: Glob
        let wholePath: Bool

        init(_ pattern: String) {
            let pattern = pattern.lowercased()
            wholePath = pattern.contains("/")
            glob = Glob(wholePath && !pattern.hasPrefix("**/") ? "**/" + pattern : pattern)
        }

        func matches(path: [UInt8], name: [UInt8]) -> Bool { glob.matches(wholePath ? path : name) }
    }

    /// Glob matching: `**/` any number of folders, `/**` everything below,
    /// `*` anything but a slash, `?` one character.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        Glob(pattern).matches(Array(text.utf8))
    }

    /// A glob compiled to tokens, matched in one pass over the text's bytes,
    /// keeping the set of places in the pattern the text so far could reach.
    struct Glob: Sendable {
        enum Token: Sendable, Equatable {
            case byte(UInt8)
            /// `?`
            case one
            /// `*`: anything but a slash.
            case star
            /// `**`: anything.
            case anything
            /// `**/`: nothing, or anything ending in a slash.
            case folders
        }

        let tokens: [Token]
        /// The pattern's longest run of plain characters, which any text it
        /// matches contains: most texts are turned down by that alone.
        private let required: [UInt8]

        init(_ pattern: String) {
            let bytes = Array(pattern.utf8)
            var tokens: [Token] = []
            var i = 0
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "*") where i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "*"):
                    if i + 2 < bytes.count, bytes[i + 2] == UInt8(ascii: "/") {
                        tokens.append(.folders)
                        i += 3
                    } else {
                        tokens.append(.anything)
                        i += 2
                    }
                    continue
                case UInt8(ascii: "*"): tokens.append(.star)
                case UInt8(ascii: "?"): tokens.append(.one)
                case let byte: tokens.append(.byte(byte))
                }
                i += 1
            }
            self.tokens = tokens
            var longest: [UInt8] = []
            var run: [UInt8] = []
            for token in tokens + [.one] {
                if case .byte(let byte) = token { run.append(byte); continue }
                if run.count > longest.count { longest = run }
                run = []
            }
            required = longest
        }

        func matches(_ text: [UInt8]) -> Bool {
            if !required.isEmpty {
                guard text.count >= required.count else { return false }
                let found = text.withUnsafeBytes { haystack in
                    required.withUnsafeBytes { needle in
                        memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
                    }
                }
                guard found else { return false }
            }
            let count = tokens.count
            // the places reached, in order, each once; `closed`, those whose
            // tokens that can match nothing have let the next one start too
            var current: [Int] = []
            var seen = [Bool](repeating: false, count: count + 1)
            var closed = seen
            func add(_ state: Int, to states: inout [Int], closing: Bool = true) {
                var state = state
                var closing = closing
                while true {
                    if !seen[state] {
                        seen[state] = true
                        states.append(state)
                    }
                    guard closing, state < count, !closed[state] else { return }
                    closed[state] = true
                    switch tokens[state] {
                    case .star, .anything, .folders: state += 1
                    case .byte, .one: return
                    }
                    closing = true
                }
            }
            add(0, to: &current)
            let slash = UInt8(ascii: "/")
            var next: [Int] = []
            for byte in text {
                for i in seen.indices {
                    seen[i] = false
                    closed[i] = false
                }
                next.removeAll(keepingCapacity: true)
                for state in current where state < count {
                    switch tokens[state] {
                    case .byte(let wanted): if wanted == byte { add(state + 1, to: &next) }
                    case .one: add(state + 1, to: &next)
                    case .star: if byte != slash { add(state, to: &next) }
                    case .anything: add(state, to: &next)
                    case .folders:
                        // inside a folder's name it can't end; after its slash it can
                        add(state, to: &next, closing: false)
                        if byte == slash { add(state + 1, to: &next) }
                    }
                }
                guard !next.isEmpty else { return false }
                swap(&current, &next)
            }
            return current.contains(count)
        }
    }
}
