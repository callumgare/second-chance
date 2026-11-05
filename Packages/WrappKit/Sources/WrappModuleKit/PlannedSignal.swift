//
//  PlannedSignal.swift
//  WrappModuleKit
//
//  A signal as planned: what to watch for while a step runs, as data
//  (decision 19 of the builders plan; docs/wrappfile.md#signals).

import Foundation

/// `SIGNAL <name>`'s watches, planned: its paths in full form, the values
/// only a running step knows (`${program.…}`) left for the watcher to fill
/// in.
public nonisolated struct PlannedSignal: Sendable, Equatable, Codable {
    public enum Combine: String, Sendable, Codable { case all, any }

    /// In full: a Wrappfile's by its own name, a module's `<id>.<name>`.
    public let name: String
    public let combine: Combine
    public let watches: [PlannedWatch]

    public init(name: String, combine: Combine, watches: [PlannedWatch]) {
        self.name = name
        self.combine = combine
        self.watches = watches
    }

    /// The fields its watches give, which `${signal.<field>}` reads.
    public var fields: Set<String> {
        Set(watches.flatMap(\.fields))
    }
}

/// What a line must have: the text, or a match of the pattern.
public nonisolated enum LinePattern: Sendable, Equatable, Codable {
    case contains(String)
    case matches(String)
}

/// One `WATCH`.
public nonisolated enum PlannedWatch: Sendable, Equatable, Codable {
    /// A line written to the file (a full-form path) after the step began.
    case log(path: String, pattern: LinePattern)
    /// The file exists.
    case file(path: String)
    /// A process of that name is running.
    case process(name: String)
    /// The program's process (nil), or one of that name, has a window on
    /// screen.
    case processHasWindow(name: String?)
    /// The program writes such a line to its output.
    case output(pattern: LinePattern)
    /// The program exits (with that code).
    case exits(code: Int32?)
    /// The folder's size changes.
    case grows(path: String)
    /// A module's own watch: `--wine.busy`.
    case module(id: String, watch: String, value: String?)

    /// The fields it gives: a `--matches`'s named groups, `path`, `size`,
    /// `code`.
    public var fields: [String] {
        switch self {
        case .log(_, .matches(let pattern)), .output(.matches(let pattern)): Self.groupNames(in: pattern)
        case .file: ["path"]
        case .grows: ["size"]
        case .exits: ["code"]
        default: []
        }
    }

    /// The names of a regex's named groups, `(?<name>…)`.
    public static func groupNames(in pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#) else { return [] }
        let range = NSRange(pattern.startIndex..., in: pattern)
        return regex.matches(in: pattern, range: range).compactMap { match in
            Range(match.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }
}

/// One of a module's own watches (`--wine.busy`), as its executor makes it
/// for a step: looked at once a second while the step runs, giving its
/// fields each time it fires, nil when it doesn't.
public nonisolated protocol WatchProbe: Sendable {
    func poll() -> [String: String]?
}

/// The program a step's signals are about: what `${program.…}` reads, each a
/// path on this Mac.
public nonisolated struct WatchedProgram: Sendable, Equatable {
    public var path: String
    public var log: String?

    public init(path: String, log: String? = nil) {
        self.path = path
        self.log = log
    }

    /// `${program.<field>}`: `path`, `dir`, `name` and `log`.
    public func field(_ name: String) -> String? {
        switch name {
        case "path": path
        case "dir": (path as NSString).deletingLastPathComponent
        case "name": (path as NSString).lastPathComponent
        case "log": log
        default: nil
        }
    }

    /// `text` with each `${program.<field>}` filled in; nil while one it
    /// reads isn't known.
    public func fill(_ text: String) -> String? {
        var result = text
        for field in ["path", "dir", "name", "log"] where result.contains("${program.\(field)}") {
            guard let value = self.field(field) else { return nil }
            result = result.replacingOccurrences(of: "${program.\(field)}", with: value)
        }
        return result.contains("${program.") ? nil : result
    }
}
