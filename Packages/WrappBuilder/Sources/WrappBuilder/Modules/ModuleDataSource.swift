//
//  ModuleDataSource.swift
//  WrappBuilder
//
//  Swift generated from modules' data, for code that can't read YAML.

import Foundation

/// The parts of modules' data the wrapp needs at launch, as Swift: the
/// wrapp reads no YAML (only the builder does), so `sc generate` writes
/// these, and a test fails when one isn't what the data makes.
public nonisolated enum ModuleDataSource {
    /// A line pattern and why it's routine.
    struct RoutineError: Decodable {
        let pattern: String
        let why: String
    }

    /// Where the routine errors' Swift lives, from the repo's root.
    public static let routineErrorsPath = "Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/GameQuitCheck+RoutineErrors.swift"

    /// `GameQuitCheck`'s routine errors: the wine module's, and the steam
    /// module's for a game launched through Steam.
    public static func routineErrorsSource(modules loader: ModuleLoader) throws -> String {
        func errors(_ module: String) throws -> [RoutineError] {
            guard let folder = loader.module(module) else {
                throw ModuleReleases.RecordError(description: "the \(module) module is missing or has problems")
            }
            return try ModuleLoader.table("routine-errors.yaml", of: folder, as: [RoutineError].self)
        }
        func list(_ name: String, _ errors: [RoutineError], doc: String) -> [String] {
            ["    /// \(doc)", "    static let \(name) = ["]
                + errors.flatMap { error in
                    wrapped(error.why, width: 70).map { "        // \($0)" } + ["        \(literal(error.pattern)),"]
                }
                + ["    ]"]
        }
        var lines = [
            "//",
            "//  GameQuitCheck+RoutineErrors.swift",
            "//  Shared",
            "//",
            "//  Generated from Modules/wine/routine-errors.yaml and",
            "//  Modules/steam/routine-errors.yaml by `sc generate`. Don't edit it:",
            "//  change the modules' data and run that again. A test fails when this",
            "//  file isn't what the data makes.",
            "",
            "nonisolated extension GameQuitCheck {",
        ]
        lines += list("routineErrors", try errors("wine"),
                      doc: "Wine's err: lines that say nothing is wrong (the wine module's).")
        lines.append("")
        lines += list("routineSteamErrors", try errors("steam"),
                      doc: "What Steam logs as it starts, as well, for a game launched through it (the steam module's).")
        lines += ["}", ""]
        return lines.joined(separator: "\n")
    }

    /// `text`'s words in lines of at most `width` characters.
    static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !line.isEmpty, line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
